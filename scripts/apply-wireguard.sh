#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root_for_firewall
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
conf="$PROJECT_ROOT/config/generated/$loc/wireguard/wg-pdns.conf"
[[ -f "$conf" ]] || fatal "missing $conf; run setup-cluster.sh or bootstrap-location.sh first"
need wg
need wg-quick
install -d -m 700 /etc/wireguard
install -m 600 "$conf" /etc/wireguard/wg-pdns.conf
systemctl enable --now wg-quick@wg-pdns
wg show wg-pdns
