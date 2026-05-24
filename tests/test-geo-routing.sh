#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
loc="${1:-eu-ams}"
load_env "$loc"
need dig
name="${2:-www.example-geo.test}"
server="${3:-$PUBLIC_DNS_IP}"

declare -A tests=(
  [EU]="80.101.1.1/32:203.0.113.10"
  [NA]="8.8.8.8/32:198.51.100.10"
  [AS]="202.12.27.33/32:192.0.2.10"
)

fail=0
for region in "${!tests[@]}"; do
  subnet="${tests[$region]%%:*}"
  expected="${tests[$region]##*:}"
  got="$(dig "@$server" "$name" A +short +subnet="$subnet" +time=2 +tries=1 | tail -n1)"
  printf '%s ECS %s -> %s expected %s\n' "$region" "$subnet" "${got:-NO_ANSWER}" "$expected"
  [[ "$got" == "$expected" ]] || fail=1
done
exit "$fail"
