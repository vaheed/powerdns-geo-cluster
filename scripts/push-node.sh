#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"
need rsync
remote_user="${SSH_USER:-root}"
remote_port="${SSH_PORT:-22}"
remote_host="$PUBLIC_DNS_IP"
remote_path="/opt/powerdns-geo-cluster"
ssh_cmd="ssh -p $remote_port"
if [[ -n "${SSH_KEY:-}" ]]; then ssh_cmd="ssh -i $SSH_KEY -p $remote_port"; fi
rsync -az --delete -e "$ssh_cmd" \
  --exclude 'data/postgres/*' --exclude 'run/*' --exclude 'logs/*' \
  "$PROJECT_ROOT/" "$remote_user@$remote_host:$remote_path/"
log "pushed repository to $remote_user@$remote_host:$remote_path"
