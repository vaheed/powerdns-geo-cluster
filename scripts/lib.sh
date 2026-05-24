#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
log_json() {
  local level="$1"; shift
  local msg="$1"; shift || true
  local component="${1:-script}"
  local loc="${LOCATION_NAME:-unknown}"
  local esc_msg="${msg//\\/\\\\}"
  esc_msg="${esc_msg//\"/\\\"}"
  printf '{"ts":"%s","level":"%s","msg":"%s","loc":"%s","component":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$esc_msg" "$loc" "$component"
}
fatal() { log_json error "$*" "lib"; printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"; }

load_env() {
  local loc="${1:-}"
  [[ -f "$PROJECT_ROOT/.env" ]] || fatal ".env not found. Copy env.example to .env or run scripts/setup-cluster.sh"
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  if [[ -n "$loc" ]]; then
    [[ -f "$PROJECT_ROOT/config/locations/$loc.env" ]] || fatal "missing config/locations/$loc.env"
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/config/locations/$loc.env"
  fi
  set +a
}

csv_to_nft_set() {
  local value="$1"
  value="${value// /}"
  [[ -n "$value" ]] || { printf '127.0.0.1/32'; return; }
  printf '%s' "$value" | sed 's/,/, /g'
}

random_secret() {
  openssl rand -base64 32 | tr -d '\n'
}

require_root_for_firewall() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "this command must run as root"
}
