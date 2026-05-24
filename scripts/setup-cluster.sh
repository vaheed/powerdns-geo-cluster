#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need openssl
need sed
need awk
need wg

cd "$PROJECT_ROOT"
mkdir -p config/locations config/generated secrets/wireguard secrets/postgres-tls data/geoip logs run/backups/tmp
[[ -f .env ]] || cp env.example .env

ask() {
  local prompt="$1" default="${2:-}" secret="${3:-false}" value
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt${default:+ [$default]}: " value; echo >&2
  else
    read -r -p "$prompt${default:+ [$default]}: " value
  fi
  printf '%s' "${value:-$default}"
}

replace_env() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

log "Interactive first-machine cluster setup"
cluster_name="$(ask 'Cluster name' 'powerdns-geo-cluster')"
mgmt_cidrs="$(ask 'Management CIDRs allowed for SSH/API, comma-separated' 'CHANGE_ME_ADMIN_PUBLIC_IP_OR_CIDR')"
ssh_user_default="$(ask 'Default SSH user for nodes' 'root')"
ssh_port_default="$(ask 'Default SSH port for nodes' '22')"
ssh_key_default="$(ask 'SSH private key path for deployment, blank for default agent/password' '')"
ssh_password_default=""
if [[ -z "$ssh_key_default" ]]; then
  ssh_password_default="$(ask 'SSH password for temporary bootstrap, blank to use SSH agent only' '' true)"
fi
wg_port="$(ask 'WireGuard UDP port' '51820')"
wg_cidr="$(ask 'WireGuard CIDR' '10.90.0.0/24')"

pdns_key="$(random_secret)"
pdns_web_pw="$(random_secret)"
pg_pw="$(random_secret)"
repl_pw="$(random_secret)"
backup_pass="$(random_secret)"
mkdir -p secrets
printf '%s\n' "$backup_pass" > secrets/backup-gpg-passphrase
chmod 600 secrets/backup-gpg-passphrase

replace_env COMPOSE_PROJECT_NAME "$cluster_name"
replace_env PDNS_API_KEY "$pdns_key"
replace_env PDNS_WEBSERVER_PASSWORD "$pdns_web_pw"
replace_env POSTGRES_PASSWORD "$pg_pw"
replace_env POSTGRES_REPLICATION_PASSWORD "$repl_pw"
replace_env MGMT_ALLOWED_CIDRS "$mgmt_cidrs"
replace_env SSH_USER "$ssh_user_default"
replace_env SSH_PORT "$ssh_port_default"
replace_env SSH_KEY "$ssh_key_default"
replace_env SSH_PASSWORD "$ssh_password_default"
replace_env WIREGUARD_PORT "$wg_port"
replace_env WIREGUARD_NETWORK_CIDR "$wg_cidr"
replace_env BACKUP_GPG_PASSPHRASE_FILE './secrets/backup-gpg-passphrase'

maxmind_account="$(ask 'MaxMind account ID, blank to skip GeoLite2 download' '')"
maxmind_key=""
if [[ -n "$maxmind_account" ]]; then
  maxmind_key="$(ask 'MaxMind license key' '' true)"
fi
replace_env MAXMIND_ACCOUNT_ID "$maxmind_account"
replace_env MAXMIND_LICENSE_KEY "$maxmind_key"

s3_bucket="$(ask 'S3 bucket for encrypted backups' 'CHANGE_ME_BUCKET_NAME')"
s3_prefix="$(ask 'S3 prefix' 'powerdns-geo-cluster')"
s3_region="$(ask 'S3 region' 'eu-west-1')"
s3_sse="$(ask 'S3 SSE mode: aws:kms or AES256' 'aws:kms')"
s3_kms=""
if [[ "$s3_sse" == "aws:kms" ]]; then
  s3_kms="$(ask 'S3 KMS key ID or alias' 'CHANGE_ME_KMS_KEY_ID_OR_ALIAS')"
fi
replace_env S3_BUCKET "$s3_bucket"
replace_env S3_PREFIX "$s3_prefix"
replace_env S3_REGION "$s3_region"
replace_env S3_SSE_MODE "$s3_sse"
replace_env S3_KMS_KEY_ID "$s3_kms"

nodes=(eu-ams us-nyc as-teh)
roles=(primary standby standby)
regions=(EU NA AS)
cities=(Amsterdam "New York" Tehran)
wgips=(10.90.0.10 10.90.0.20 10.90.0.30)

node_publics=()
node_wgpubs=()
node_sshusers=()
node_sshports=()

for i in "${!nodes[@]}"; do
  loc="${nodes[$i]}"
  role="${roles[$i]}"
  region="${regions[$i]}"
  city="${cities[$i]}"
  pub="$(ask "Public DNS IP for $loc" "CHANGE_ME_${loc^^}_PUBLIC_IP")"
  wgip="$(ask "WireGuard IP for $loc" "${wgips[$i]}")"
  wgips[$i]="$wgip"
  ssh_user="$(ask "SSH user for $loc" "$ssh_user_default")"
  ssh_port="$(ask "SSH port for $loc" "$ssh_port_default")"

  priv="$(wg genkey)"
  pubkey="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" > "secrets/wireguard/$loc.private"
  printf '%s\n' "$pubkey" > "secrets/wireguard/$loc.public"
  chmod 600 "secrets/wireguard/$loc.private"

  slot=""
  phosts=""
  if [[ "$role" == "standby" ]]; then
    slot="eu_ams_${loc//-/_}"
    phosts="${wgips[0]},${node_publics[0]}"
  fi

  cat > "config/locations/$loc.env" <<EOF
LOCATION_NAME=$loc
LOCATION_ROLE=$role
REGION_CODE=$region
LOCATION_CITY="$city"
PUBLIC_DNS_IP=$pub
WG_IPV4=$wgip
WG_IPV4_CIDR=$wgip/24
WG_PORT=$wg_port
WG_PRIVATE_KEY=$priv
WG_PUBLIC_KEY=$pubkey
POSTGRES_PRIMARY_HOSTS=$phosts
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=$slot
DOCKER_DNS_SUBNET=172.30.$((10 + i*10)).0/24
EOF

  node_publics+=("$pub")
  node_wgpubs+=("$pubkey")
  node_sshusers+=("$ssh_user")
  node_sshports+=("$ssh_port")
done

peer_cidrs=""
for pub in "${node_publics[@]}"; do
  [[ -n "$peer_cidrs" ]] && peer_cidrs+=","
  peer_cidrs+="$pub/32"
done
printf '%s\n' "$peer_cidrs" > config/generated/cluster-peer-public-cidrs

cat > cluster-inventory.yml <<EOF
cluster:
  name: $cluster_name
  primary: eu-ams
  wireguard_network_cidr: $wg_cidr
  wireguard_port: $wg_port
  postgres_public_fallback_enabled: true
  backup_target: s3
nodes:
EOF
for i in "${!nodes[@]}"; do
  cat >> cluster-inventory.yml <<EOF
  - name: ${nodes[$i]}
    role: ${roles[$i]}
    region_code: ${regions[$i]}
    city: ${cities[$i]}
    public_dns_ip: ${node_publics[$i]}
    wireguard_ip: ${wgips[$i]}
    ssh_user: ${node_sshusers[$i]}
    ssh_port: ${node_sshports[$i]}
EOF
done

./scripts/generate-wireguard-configs.sh
./scripts/generate-postgres-tls.sh eu-ams "${node_publics[0]}" "${wgips[0]}"
for loc in "${nodes[@]}"; do
  ./scripts/render-config.sh "$loc"
done

log "Cluster files generated. Next steps:"
echo "1. Copy this directory to each node, including secrets/. Protect it as root-only."
echo "2. On each node: sudo ./scripts/apply-wireguard.sh LOCATION"
echo "3. Start primary first: ./scripts/node-compose.sh eu-ams up -d --build"
echo "4. Start standbys: ./scripts/node-compose.sh us-nyc up -d --build and ./scripts/node-compose.sh as-teh up -d --build"
echo "5. Enable nftables after confirming SSH management CIDRs: sudo ./scripts/install-nftables.sh LOCATION"
