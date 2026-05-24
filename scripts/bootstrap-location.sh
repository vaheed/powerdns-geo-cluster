#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need wg

usage() {
  cat >&2 <<'EOF'
usage: scripts/bootstrap-location.sh [--interactive] LOCATION PUBLIC_DNS_IP WIREGUARD_IP REGION_CODE [SSH_USER] [SSH_PORT]

Example:
  ./scripts/bootstrap-location.sh eu-fra 203.0.113.44 10.90.0.40 EU root 22
EOF
  exit 2
}

if [[ "${1:-}" == "--interactive" ]]; then
  read -r -p "Location name: " loc
  read -r -p "Public DNS IP: " public_ip
  read -r -p "WireGuard IP, example 10.90.0.40: " wg_ip
  read -r -p "Region code, example EU/NA/AS: " region
  read -r -p "SSH user [root]: " ssh_user; ssh_user="${ssh_user:-root}"
  read -r -p "SSH port [22]: " ssh_port; ssh_port="${ssh_port:-22}"
else
  [[ $# -ge 4 ]] || usage
  loc="$1"; public_ip="$2"; wg_ip="$3"; region="$4"; ssh_user="${5:-root}"; ssh_port="${6:-22}"
fi

load_env
[[ "$loc" =~ ^[a-z0-9][a-z0-9-]+$ ]] || fatal "invalid location name: $loc"
mkdir -p "$PROJECT_ROOT/config/locations" "$PROJECT_ROOT/secrets/wireguard"

if [[ -f "$PROJECT_ROOT/config/locations/$loc.env" ]]; then
  log "$loc already exists; refreshing rendered config only"
else
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" > "$PROJECT_ROOT/secrets/wireguard/$loc.private"
  printf '%s\n' "$pub" > "$PROJECT_ROOT/secrets/wireguard/$loc.public"
  chmod 600 "$PROJECT_ROOT/secrets/wireguard/$loc.private"
  slot="eu_ams_${loc//-/_}"
  primary_public="$(awk -F= '/^PUBLIC_DNS_IP=/{print $2; exit}' "$PROJECT_ROOT/config/locations/eu-ams.env")"
  cat > "$PROJECT_ROOT/config/locations/$loc.env" <<EOF
LOCATION_NAME=$loc
LOCATION_ROLE=standby
REGION_CODE=$region
LOCATION_CITY="$loc"
PUBLIC_DNS_IP=$public_ip
WG_IPV4=$wg_ip
WG_IPV4_CIDR=$wg_ip/24
WG_PORT=${WIREGUARD_PORT:-51820}
WG_PRIVATE_KEY=$priv
WG_PUBLIC_KEY=$pub
POSTGRES_PRIMARY_HOSTS=10.90.0.10,$primary_public
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=$slot
DOCKER_DNS_SUBNET=172.30.$((RANDOM % 100 + 40)).0/24
EOF
fi

# Update peer public CIDRs.
peers=""
for f in "$PROJECT_ROOT"/config/locations/*.env; do
  pub="$(awk -F= '/^PUBLIC_DNS_IP=/{print $2; exit}' "$f")"
  [[ -n "$pub" ]] || continue
  [[ -n "$peers" ]] && peers+=","
  peers+="$pub/32"
done
mkdir -p "$PROJECT_ROOT/config/generated"
printf '%s\n' "$peers" > "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs"

# Add to inventory if not present.
if ! grep -q "name: $loc" "$PROJECT_ROOT/cluster-inventory.yml"; then
  cat >> "$PROJECT_ROOT/cluster-inventory.yml" <<EOF
  - name: $loc
    role: standby
    region_code: $region
    city: $loc
    public_dns_ip: $public_ip
    wireguard_ip: $wg_ip
    ssh_user: $ssh_user
    ssh_port: $ssh_port
EOF
fi

if [[ ! -f "$PROJECT_ROOT/docker-compose.$loc.yml" ]]; then
  cat > "$PROJECT_ROOT/docker-compose.$loc.yml" <<EOF
services:
  pdns:
    container_name: pdns-auth-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "pdns-auth"
  postgres:
    container_name: pdns-postgres-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "postgres"
  geoipupdate:
    container_name: pdns-geoipupdate-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "geoipupdate"
EOF
fi

./scripts/generate-wireguard-configs.sh
./scripts/generate-postgres-tls.sh
for envfile in "$PROJECT_ROOT"/config/locations/*.env; do
  node="$(basename "$envfile" .env)"
  ./scripts/render-config.sh "$node"
done

cat <<EOF
Location $loc is configured.

Next steps:
1. Copy the repository to $public_ip.
2. On the new node, run: sudo ./scripts/apply-wireguard.sh $loc
3. On the primary, reload WireGuard: sudo wg syncconf wg-pdns <(wg-quick strip /etc/wireguard/wg-pdns.conf)
4. On the primary, re-apply firewall: sudo ./scripts/install-nftables.sh eu-ams
5. On the new node, start services: ./scripts/node-compose.sh $loc up -d --build
6. Check replication: ./scripts/sync-zones.sh --check
EOF
