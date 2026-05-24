#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root_for_firewall
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"
need nft

peer_public_cidrs="127.0.0.1/32"
if [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]]; then
  peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"
fi

mgmt_set="$(csv_to_nft_set "${MGMT_ALLOWED_CIDRS:-127.0.0.1/32}")"
peer_set="$(csv_to_nft_set "$peer_public_cidrs")"

rendered="/etc/nftables.d/pdns-geo.nft"
mkdir -p /etc/nftables.d
sed \
  -e "s|__MGMT_ALLOWED_CIDRS__|$mgmt_set|g" \
  -e "s|__PEER_PUBLIC_CIDRS__|$peer_set|g" \
  -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
  -e "s|__PUBLIC_DNS_IP__|${PUBLIC_DNS_IP}|g" \
  -e "s|__WG_IPV4__|${WG_IPV4}|g" \
  -e "s|__SSH_PORT__|${SSH_PORT:-22}|g" \
  -e "s|__WIREGUARD_PORT__|${WG_PORT:-51820}|g" \
  "$PROJECT_ROOT/scripts/nftables/pdns-geo.nft" > "$rendered"

nft -c -f "$rendered"
nft -f "$rendered"
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
include "$rendered"
EOF
systemctl enable nftables >/dev/null 2>&1 || true
log "nftables rules applied from $rendered"
