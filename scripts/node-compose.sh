#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 2 ]] || { echo "usage: $0 LOCATION compose-args..." >&2; exit 2; }
LOC="$1"; shift
[[ -f "$ROOT/.env" ]] || { echo ".env missing" >&2; exit 1; }
[[ -f "$ROOT/config/locations/$LOC.env" ]] || { echo "config/locations/$LOC.env missing" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
# shellcheck disable=SC1091
source "$ROOT/config/locations/$LOC.env"
set +a
cd "$ROOT"
exec docker compose -f docker-compose.yml -f "docker-compose.$LOC.yml" "$@"
