#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-${LOCATION_NAME:-eu-ams}}"
load_env "$loc"
need docker
need curl
need dig

fail=0
check() { echo "== $*"; "$@" || fail=1; }
check docker ps --format 'table {{.Names}}\t{{.Status}}'
check curl -fsS -H "X-API-Key: $PDNS_API_KEY" "http://${PDNS_API_BIND}:${PDNS_API_PORT}/api/v1/servers/localhost"
check docker exec "pdns-postgres-$LOCATION_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1
check dig "@${PUBLIC_DNS_IP}" example-geo.test SOA +time=2 +tries=1
./scripts/sync-zones.sh --check || fail=1
exit "$fail"
