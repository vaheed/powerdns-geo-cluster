#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

loc="${1:-${LOCATION_NAME:-}}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"

out="$PROJECT_ROOT/config/generated/$loc"
mkdir -p "$out/pdns" "$out/db" "$out/wireguard"

peer_public_cidrs=""
if [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]]; then
  peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"
fi
: "${peer_public_cidrs:=127.0.0.1/32}"

public_hba=""
if [[ "${POSTGRES_PUBLIC_FALLBACK_ENABLED:-true}" == "true" ]]; then
  IFS=',' read -ra peers <<< "$peer_public_cidrs"
  for cidr in "${peers[@]}"; do
    cidr="${cidr// /}"
    [[ -n "$cidr" ]] || continue
    public_hba+="hostssl replication ${POSTGRES_REPLICATION_USER} ${cidr} scram-sha-256"$'\n'
  done
fi

mgmt_hba="$(csv_to_nft_set "${MGMT_ALLOWED_CIDRS:-127.0.0.1/32}")"
# pg_hba does not accept nft set syntax. Use only the first management CIDR for DB admin by default.
mgmt_first="${MGMT_ALLOWED_CIDRS%%,*}"
mgmt_first="${mgmt_first// /}"
: "${mgmt_first:=127.0.0.1/32}"

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
log "rendered config for $loc in $out"
