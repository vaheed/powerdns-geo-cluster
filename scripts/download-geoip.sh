#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-eu-ams}"
load_env "$loc"
[[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]] || fatal "set MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY in .env"
./scripts/node-compose.sh "$loc" --profile geoip run --rm geoipupdate
ls -lh "$PROJECT_ROOT/data/geoip"
