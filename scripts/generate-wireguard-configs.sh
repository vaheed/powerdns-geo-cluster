#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env
need wg
mkdir -p "$PROJECT_ROOT/config/generated"

mapfile -t locs < <(ls "$PROJECT_ROOT/config/locations"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//')
[[ ${#locs[@]} -gt 0 ]] || fatal "no location env files found"

for loc in "${locs[@]}"; do
  load_env "$loc"
  out="$PROJECT_ROOT/config/generated/$loc/wireguard"
  mkdir -p "$out"
  umask 077
  {
    echo "[Interface]"
    echo "Address = ${WG_IPV4_CIDR}"
    echo "ListenPort = ${WG_PORT}"
    echo "PrivateKey = ${WG_PRIVATE_KEY}"
    echo "MTU = ${WIREGUARD_MTU:-1420}"
    echo ""
    for peer in "${locs[@]}"; do
      [[ "$peer" == "$loc" ]] && continue
      set -a; source "$PROJECT_ROOT/config/locations/$peer.env"; set +a
      peer_pub="$WG_PUBLIC_KEY"
      peer_wg="$WG_IPV4"
      peer_public="$PUBLIC_DNS_IP"
      peer_port="$WG_PORT"
      echo "[Peer]"
      echo "PublicKey = $peer_pub"
      echo "AllowedIPs = $peer_wg/32"
      echo "Endpoint = $peer_public:$peer_port"
      echo "PersistentKeepalive = ${WIREGUARD_PERSISTENT_KEEPALIVE:-25}"
      echo ""
    done
  } > "$out/wg-pdns.conf"
done
log "generated WireGuard configs under config/generated/*/wireguard/wg-pdns.conf"
