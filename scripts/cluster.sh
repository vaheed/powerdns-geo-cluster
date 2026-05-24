#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=./lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'TXT'
Single command interface for setup + operations.

Setup:
  ./scripts/cluster.sh install-deps
  ./scripts/cluster.sh init
  ./scripts/cluster.sh render [location|all]
  ./scripts/cluster.sh wireguard generate
  ./scripts/cluster.sh wireguard apply <location>
  ./scripts/cluster.sh tls generate
  ./scripts/cluster.sh firewall apply <location>

Runtime:
  ./scripts/cluster.sh up <location>
  ./scripts/cluster.sh down <location>
  ./scripts/cluster.sh restart <location>
  ./scripts/cluster.sh status <location>
  ./scripts/cluster.sh monitoring on <location>
  ./scripts/cluster.sh monitoring off <location>

Ops:
  ./scripts/cluster.sh check [location]
  ./scripts/cluster.sh replication check <location>
  ./scripts/cluster.sh backup [location]
  ./scripts/cluster.sh restore <s3-uri> [location]
  ./scripts/cluster.sh failover <standby-location>
  ./scripts/cluster.sh deploy
  ./scripts/cluster.sh validate
  ./scripts/cluster.sh smoke
TXT
}

compose_for_loc() {
  local loc="$1"
  [[ -f "$PROJECT_ROOT/config/locations/$loc.env" ]] || fatal "missing config/locations/$loc.env"
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  # shellcheck disable=SC1090
  source "$PROJECT_ROOT/config/locations/$loc.env"
  set +a
  local -a files=( -f docker-compose.yml -f "docker-compose.$loc.yml" )
  local -a profiles=()
  if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
    files+=( -f docker-compose.monitoring.yml )
    profiles+=( --profile monitoring )
  fi
  docker compose "${files[@]}" "${profiles[@]}" "${@:2}"
}

render_one() {
  local loc="$1"
  load_env "$loc"
  local out="$PROJECT_ROOT/config/generated/$loc"
  mkdir -p "$out/pdns" "$out/db" "$out/wireguard"

  local peer_public_cidrs="127.0.0.1/32"
  [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]] && peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"

  local public_hba=""
  if [[ "${POSTGRES_PUBLIC_FALLBACK_ENABLED:-true}" == "true" ]]; then
    IFS=',' read -ra peers <<< "$peer_public_cidrs"
    for cidr in "${peers[@]}"; do
      cidr="${cidr// /}"; [[ -n "$cidr" ]] || continue
      public_hba+="hostssl replication ${POSTGRES_REPLICATION_USER} ${cidr} scram-sha-256"$'\n'
    done
  fi

  local mgmt_first="${MGMT_ALLOWED_CIDRS%%,*}"; mgmt_first="${mgmt_first// /}"; : "${mgmt_first:=127.0.0.1/32}"

  sed \
    -e "s|__POSTGRES_DB__|${POSTGRES_DB}|g" \
    -e "s|__POSTGRES_USER__|${POSTGRES_USER}|g" \
    -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
    -e "s|__PDNS_API_KEY__|${PDNS_API_KEY}|g" \
    -e "s|__PDNS_WEBSERVER_PASSWORD__|${PDNS_WEBSERVER_PASSWORD}|g" \
    -e "s|__MGMT_ALLOWED_CIDRS__|${MGMT_ALLOWED_CIDRS}|g" \
    -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
    -e "s|__PDNS_LOGLEVEL__|${PDNS_LOGLEVEL:-4}|g" \
    "$PROJECT_ROOT/config/pdns/pdns.conf.template" > "$out/pdns/pdns.conf"

  sed \
    -e "s|__POSTGRES_WAL_KEEP_SIZE__|${POSTGRES_WAL_KEEP_SIZE:-2048MB}|g" \
    -e "s|__POSTGRES_MAX_SLOT_WAL_KEEP_SIZE__|${POSTGRES_MAX_SLOT_WAL_KEEP_SIZE:-10240MB}|g" \
    "$PROJECT_ROOT/config/db/postgresql.conf.template" > "$out/db/postgresql.conf"

  sed \
    -e "s|__DOCKER_DNS_SUBNET__|${DOCKER_DNS_SUBNET}|g" \
    -e "s|__REPL_USER__|${POSTGRES_REPLICATION_USER}|g" \
    -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
    -e "s|__PUBLIC_REPLICATION_HBA__|${public_hba//$'\n'/\\n}|g" \
    -e "s|__MGMT_ALLOWED_CIDRS__|${mgmt_first}|g" \
    "$PROJECT_ROOT/config/db/pg_hba.conf.template" | sed 's/\\n/\
/g' > "$out/db/pg_hba.conf"

  chmod 600 "$out/db/pg_hba.conf" "$out/pdns/pdns.conf"
  log_json info "rendered config" "render"
}

wireguard_generate() {
  load_env
  need wg
  mkdir -p "$PROJECT_ROOT/config/generated"
  mapfile -t locs < <(find "$PROJECT_ROOT/config/locations" -maxdepth 1 -type f -name '*.env' -exec basename {} .env \; | sort)
  [[ ${#locs[@]} -gt 0 ]] || fatal "no location env files found"
  for loc in "${locs[@]}"; do
    load_env "$loc"
    local out="$PROJECT_ROOT/config/generated/$loc/wireguard"
    mkdir -p "$out"
    local priv_file="$PROJECT_ROOT/secrets/wireguard/$loc.private"
    [[ -f "$priv_file" ]] || fatal "missing WireGuard private key file: $priv_file"
    local priv_key; priv_key="$(tr -d '\r\n' < "$priv_file")"
    {
      echo "[Interface]"
      echo "Address = ${WG_IPV4_CIDR}"
      echo "ListenPort = ${WG_PORT:-51820}"
      echo "PrivateKey = ${priv_key}"
      echo "MTU = ${WIREGUARD_MTU:-1420}"
      echo
      for peer in "${locs[@]}"; do
        [[ "$peer" == "$loc" ]] && continue
        (
          set -a
          # shellcheck disable=SC1090
          source "$PROJECT_ROOT/config/locations/$peer.env"
          set +a
          echo "[Peer]"
          echo "PublicKey = $WG_PUBLIC_KEY"
          echo "AllowedIPs = $WG_IPV4/32"
          echo "Endpoint = $PUBLIC_DNS_IP:$WG_PORT"
          echo "PersistentKeepalive = ${WIREGUARD_PERSISTENT_KEEPALIVE:-25}"
          echo
        )
      done
    } > "$out/wg-pdns.conf"
  done
}

tls_generate() {
  need openssl
  local tls_root="$PROJECT_ROOT/secrets/postgres-tls"
  local ca_dir="$tls_root/ca"
  mkdir -p "$ca_dir"
  chmod 700 "$tls_root" "$ca_dir"
  if [[ ! -f "$ca_dir/ca.key" ]]; then
    openssl genrsa -out "$ca_dir/ca.key" 4096 >/dev/null 2>&1
    openssl req -x509 -new -nodes -key "$ca_dir/ca.key" -sha256 -days 3650 -subj "/CN=powerdns-geo-postgres-ca" -out "$ca_dir/ca.crt" >/dev/null 2>&1
    chmod 600 "$ca_dir/ca.key"
  fi
  for envfile in "$PROJECT_ROOT"/config/locations/*.env; do
    [[ -f "$envfile" ]] || continue
    set -a
    # shellcheck disable=SC1090
    source "$envfile"
    set +a
    local node
    node="$(basename "$envfile" .env)"
    mkdir -p "$tls_root/$node"
    chmod 700 "$tls_root/$node"
    cat > "$tls_root/$node/server.cnf" <<CNF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext
[dn]
CN = postgres-$node
[req_ext]
subjectAltName = @alt_names
[alt_names]
DNS.1 = postgres
DNS.2 = postgres-$node
DNS.3 = pdns-postgres-$node
IP.1 = $PUBLIC_DNS_IP
IP.2 = $WG_IPV4
IP.3 = 127.0.0.1
CNF
    openssl genrsa -out "$tls_root/$node/server.key" 4096 >/dev/null 2>&1
    openssl req -new -key "$tls_root/$node/server.key" -out "$tls_root/$node/server.csr" -config "$tls_root/$node/server.cnf" >/dev/null 2>&1
    openssl x509 -req -in "$tls_root/$node/server.csr" -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" -CAcreateserial -out "$tls_root/$node/server.crt" -days 825 -sha256 -extensions req_ext -extfile "$tls_root/$node/server.cnf" >/dev/null 2>&1
    cp "$ca_dir/ca.crt" "$tls_root/$node/ca.crt"
    chmod 600 "$tls_root/$node/server.key"
    rm -f "$tls_root/$node/server.csr"
  done
}

setup_init() {
  need wg
  cd "$PROJECT_ROOT"
  mkdir -p config/locations config/generated secrets/wireguard secrets/postgres-tls data/geoip logs run/backups/tmp
  [[ -f .env ]] || cp env.example .env

  ask() {
    local p="$1" d="${2:-}" s="${3:-false}" v
    if [[ "$s" == "true" ]]; then read -r -s -p "$p${d:+ [$d]}: " v; echo
    else read -r -p "$p${d:+ [$d]}: " v; fi
    printf '%s' "${v:-$d}"
  }
  replace_env() { if grep -qE "^$1=" .env; then sed -i.bak "s|^$1=.*|$1=$2|" .env; else printf '%s=%s\n' "$1" "$2" >> .env; fi; }

  local cluster_name; cluster_name="$(ask 'Cluster name' 'powerdns-geo-cluster')"
  local mgmt_cidrs; mgmt_cidrs="$(ask 'Management CIDRs' 'CHANGE_ME_ADMIN_PUBLIC_IP_OR_CIDR')"
  local wg_port; wg_port="$(ask 'WireGuard UDP port' '51820')"
  local wg_cidr; wg_cidr="$(ask 'WireGuard CIDR' '10.90.0.0/24')"
  local pdns_key; pdns_key="$(random_secret)"
  local pdns_web_pw; pdns_web_pw="$(random_secret)"
  local pg_pw; pg_pw="$(random_secret)"
  local repl_pw; repl_pw="$(random_secret)"
  local backup_pass; backup_pass="$(random_secret)"
  printf '%s\n' "$backup_pass" > secrets/backup-gpg-passphrase
  printf '%s\n' "$repl_pw" > secrets/postgres-replication-password
  chmod 600 secrets/backup-gpg-passphrase secrets/postgres-replication-password

  replace_env COMPOSE_PROJECT_NAME "$cluster_name"
  replace_env PDNS_API_KEY "$pdns_key"
  replace_env PDNS_WEBSERVER_PASSWORD "$pdns_web_pw"
  replace_env POSTGRES_PASSWORD "$pg_pw"
  replace_env POSTGRES_REPLICATION_PASSWORD "$repl_pw"
  replace_env MGMT_ALLOWED_CIDRS "$mgmt_cidrs"
  replace_env WIREGUARD_PORT "$wg_port"
  replace_env WIREGUARD_NETWORK_CIDR "$wg_cidr"

  local nodes=(eu-ams us-nyc as-teh) roles=(primary standby standby) regions=(EU NA AS) cities=(Amsterdam "New York" Tehran) wgips=(10.90.0.10 10.90.0.20 10.90.0.30)
  local node_publics=()
  for i in "${!nodes[@]}"; do
    local loc role region city
    loc="${nodes[i]}"
    role="${roles[i]}"
    region="${regions[i]}"
    city="${cities[i]}"
    local pub; pub="$(ask "Public DNS IP for $loc" "CHANGE_ME_${loc^^}_PUBLIC_IP")"
    local wgip
    wgip="$(ask "WireGuard IP for $loc" "${wgips[i]}")"
    wgips[i]="$wgip"
    local priv
    priv="$(wg genkey)"
    local pubkey
    pubkey="$(printf '%s' "$priv" | wg pubkey)"
    printf '%s\n' "$priv" > "secrets/wireguard/$loc.private"
    printf '%s\n' "$pubkey" > "secrets/wireguard/$loc.public"
    chmod 600 "secrets/wireguard/$loc.private"
    local slot="" phosts=""
    if [[ "$role" == "standby" ]]; then slot="eu_ams_${loc//-/_}"; phosts="${wgips[0]},${node_publics[0]}"; fi
    cat > "config/locations/$loc.env" <<ENV
LOCATION_NAME=$loc
LOCATION_ROLE=$role
REGION_CODE=$region
LOCATION_CITY="$city"
PUBLIC_DNS_IP=$pub
WG_IPV4=$wgip
WG_IPV4_CIDR=$wgip/24
WG_PORT=$wg_port
WG_PUBLIC_KEY=$pubkey
POSTGRES_PRIMARY_HOSTS=$phosts
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=$slot
DOCKER_DNS_SUBNET=172.30.$((10 + i*10)).0/24
ENV
    node_publics+=("$pub")
  done

  printf '%s\n' "${node_publics[0]}/32,${node_publics[1]}/32,${node_publics[2]}/32" > config/generated/cluster-peer-public-cidrs
  wireguard_generate
  tls_generate
  for f in config/locations/*.env; do render_one "$(basename "$f" .env)"; done
  validate_repo
}

apply_wireguard() {
  require_root_for_firewall
  need wg; need wg-quick
  local loc="$1"
  local conf="$PROJECT_ROOT/config/generated/$loc/wireguard/wg-pdns.conf"
  [[ -f "$conf" ]] || fatal "missing $conf"
  install -d -m 700 /etc/wireguard
  install -m 600 "$conf" /etc/wireguard/wg-pdns.conf
  systemctl enable --now wg-quick@wg-pdns
}

apply_firewall() {
  require_root_for_firewall
  local loc="$1"
  load_env "$loc"
  need nft
  local peer_public_cidrs="127.0.0.1/32"
  [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]] && peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"
  local mgmt_set peer_set
  mgmt_set="$(csv_to_nft_set "${MGMT_ALLOWED_CIDRS:-127.0.0.1/32}")"
  peer_set="$(csv_to_nft_set "$peer_public_cidrs")"
  local rendered="/etc/nftables.d/pdns-geo.nft"
  mkdir -p /etc/nftables.d
  sed -e "s|__MGMT_ALLOWED_CIDRS__|$mgmt_set|g" -e "s|__PEER_PUBLIC_CIDRS__|$peer_set|g" -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" -e "s|__PUBLIC_DNS_IP__|${PUBLIC_DNS_IP}|g" -e "s|__WG_IPV4__|${WG_IPV4}|g" -e "s|__SSH_PORT__|${SSH_PORT:-22}|g" -e "s|__WIREGUARD_PORT__|${WG_PORT:-51820}|g" "$PROJECT_ROOT/scripts/nftables/pdns-geo.nft" > "$rendered"
  nft -c -f "$rendered"; nft -f "$rendered"
}

health_check() {
  local loc="${1:-eu-ams}"
  load_env "$loc"
  need docker; need curl; need dig
  local fail=0
  docker ps --format 'table {{.Names}}\t{{.Status}}' || fail=1
  curl -fsS -H "X-API-Key: $PDNS_API_KEY" "http://${PDNS_API_BIND}:${PDNS_API_PORT}/api/v1/servers/localhost" >/dev/null || fail=1
  docker exec "pdns-postgres-$LOCATION_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1 || fail=1
  dig "@${PUBLIC_DNS_IP}" example-geo.test SOA +time=2 +tries=1 >/dev/null || fail=1
  return "$fail"
}

replication_check() {
  local loc="$1"
  load_env "$loc"
  local cid="pdns-postgres-$LOCATION_NAME"
  if [[ "$LOCATION_ROLE" == "primary" ]]; then
    docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn, extract(epoch from coalesce(write_lag,'0 second'::interval)) as write_lag_s from pg_stat_replication order by application_name;"
  else
    docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "select pg_is_in_recovery() as standby, status, sender_host, sender_port, latest_end_lsn, now() - pg_last_xact_replay_timestamp() as replay_lag from pg_stat_wal_receiver;"
  fi
}

backup_db() {
  local loc="${1:-eu-ams}"
  load_env "$loc"
  need docker; need gzip; need gpg; need aws
  local rec; rec="$(docker exec "pdns-postgres-$LOCATION_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c "select pg_is_in_recovery();")"
  [[ "${rec// /}" == "f" ]] || fatal "run backups on primary only"
  local ts work
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  work="$PROJECT_ROOT/${BACKUP_TMP_DIR:-run/backups/tmp}"
  mkdir -p "$work"
  local plain gz enc sha
  plain="$work/pdns-${LOCATION_NAME}-${ts}.sql"
  gz="$plain.gz"
  enc="$gz.gpg"
  sha="$enc.sha256"
  docker exec "pdns-postgres-$LOCATION_NAME" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=plain --clean --if-exists --no-owner --no-privileges > "$plain"
  gzip -9 "$plain"
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" --symmetric --cipher-algo AES256 -o "$enc" "$gz"
  sha256sum "$enc" > "$sha"
  local s3_uri
  s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${LOCATION_NAME}/$(basename "$enc")"
  aws s3 cp "$enc" "$s3_uri" --region "$S3_REGION" ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"}
  aws s3 cp "$sha" "$s3_uri.sha256" --region "$S3_REGION" ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"}
}

restore_db() {
  local uri="$1" loc="${2:-eu-ams}"
  load_env "$loc"
  [[ "$LOCATION_ROLE" == "primary" ]] || fatal "restore must run on primary"
  need aws; need gpg; need gunzip; need docker
  local work
  work="$PROJECT_ROOT/run/restore/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$work"
  local enc="$work/backup.sql.gz.gpg" gz="$work/backup.sql.gz" sql="$work/backup.sql"
  aws s3 cp "$uri" "$enc" --region "$S3_REGION" ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"}
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$gz" -d "$enc"
  gunzip -c "$gz" > "$sql"
  echo "Type RESTORE to continue:"; read -r confirm; [[ "$confirm" == "RESTORE" ]] || fatal "restore cancelled"
  compose_for_loc "$loc" stop pdns
  docker exec -i "pdns-postgres-$LOCATION_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 < "$sql"
  compose_for_loc "$loc" start pdns
}

failover_promote() {
  local loc="$1"
  load_env "$loc"
  [[ "$LOCATION_ROLE" == "standby" ]] || fatal "location is not standby"
  docker exec "pdns-postgres-$LOCATION_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_promote(wait_seconds => 60);"
}

validate_repo() {
  local fail=0
  while IFS= read -r -d '' f; do bash -n "$f" || fail=1; done < <(find scripts docker -type f -name '*.sh' -print0)
  while IFS= read -r -d '' f; do python3 -m py_compile "$f" || fail=1; done < <(find bin monitoring -type f -name '*.py' -print0)
  python3 - <<'PY' || fail=1
import pathlib,sys,json
import yaml
ok=True
for p in pathlib.Path('.').rglob('*'):
    if p.suffix in ('.yml','.yaml'):
        try: yaml.safe_load(p.read_text())
        except Exception as e: ok=False; print(f'YAML error {p}: {e}', file=sys.stderr)
for p in pathlib.Path('monitoring/grafana/dashboards').rglob('*.json'):
    try: json.loads(p.read_text())
    except Exception as e: ok=False; print(f'JSON error {p}: {e}', file=sys.stderr)
if not ok: sys.exit(1)
PY
  [[ $fail -eq 0 ]] || fatal "validation failed"
}

smoke_test() {
  log_json info "smoke: help" "smoke"
  "$0" --help >/dev/null
  log_json info "smoke: validate" "smoke"
  "$0" validate
  log_json info "smoke: done" "smoke"
}

deploy_all() {
  load_env
  need rsync
  local remote_path="${REMOTE_PROJECT_PATH:-/opt/powerdns-geo-cluster}"
  local locations=(eu-ams us-nyc as-teh)
  for loc in "${locations[@]}"; do
    load_env "$loc"
    local remote="${SSH_USER:-root}@$PUBLIC_DNS_IP"
    ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$remote" "mkdir -p '$remote_path'"
    rsync -az --delete "$PROJECT_ROOT/" "$remote:$remote_path/"
    ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}" "$remote" "cd '$remote_path' && sudo ./scripts/cluster.sh wireguard apply '$loc' && ./scripts/cluster.sh up '$loc'"
  done
}

cmd="${1:-}"; sub="${2:-}"; arg1="${3:-}"
case "$cmd" in
  install-deps) require_root_for_firewall; apt-get update; apt-get install -y docker.io docker-compose-plugin wireguard wireguard-tools nftables openssl jq curl dnsutils awscli gnupg rsync python3 python3-pip; systemctl enable --now docker ;;
  init) setup_init ;;
  render) target="${2:-all}"; if [[ "$target" == "all" ]]; then for f in "$PROJECT_ROOT"/config/locations/*.env; do render_one "$(basename "$f" .env)"; done; else render_one "$target"; fi ;;
  wireguard) if [[ "$sub" == "generate" ]]; then wireguard_generate; else apply_wireguard "$arg1"; fi ;;
  tls) if [[ "$sub" == "generate" ]]; then tls_generate; else fatal "usage: tls generate"; fi ;;
  firewall) if [[ "$sub" == "apply" ]]; then apply_firewall "$arg1"; else fatal "usage: firewall apply <location>"; fi ;;
  up) compose_for_loc "$sub" up -d --build ;;
  down) compose_for_loc "$sub" down ;;
  restart) compose_for_loc "$sub" down; compose_for_loc "$sub" up -d --build ;;
  status) compose_for_loc "$sub" ps ;;
  monitoring) if [[ "$sub" == "on" ]]; then ENABLE_MONITORING=true compose_for_loc "$arg1" up -d --build; else ENABLE_MONITORING=false compose_for_loc "$arg1" up -d --build; fi ;;
  check) health_check "$sub" ;;
  replication) [[ "$sub" == "check" ]] || fatal "usage: replication check <location>"; replication_check "$arg1" ;;
  backup) backup_db "$sub" ;;
  restore) restore_db "$sub" "$arg1" ;;
  failover) failover_promote "$sub" ;;
  validate) validate_repo ;;
  smoke) smoke_test ;;
  deploy) deploy_all ;;
  -h|--help|help|"") usage ;;
  *) fatal "unknown command: $cmd" ;;
esac
