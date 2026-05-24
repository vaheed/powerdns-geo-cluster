#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env
need rsync

make_ssh_array() {
  SSH_ARR=()
  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    command -v sshpass >/dev/null 2>&1 || fatal "SSH_PASSWORD is set but sshpass is not installed"
    SSH_ARR+=(sshpass -p "$SSH_PASSWORD")
  fi
  SSH_ARR+=(ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}")
  if [[ -n "${SSH_KEY:-}" ]]; then
    SSH_ARR+=(-i "$SSH_KEY")
  fi
}

remote_path="${REMOTE_PROJECT_PATH:-/opt/powerdns-geo-cluster}"
locations=(eu-ams us-nyc as-teh)

cat <<MSG
This deploys generated files to nodes and starts services in order.
It assumes Docker, Compose plugin, WireGuard, nftables, awscli, gpg, curl, dig, and rsync are installed on each node.
MSG

for loc in "${locations[@]}"; do
  load_env "$loc"
  read -r -p "Deploy $loc at $PUBLIC_DNS_IP? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || continue
  remote="${SSH_USER:-root}@$PUBLIC_DNS_IP"
  make_ssh_array
  ssh_cmd_string="${SSH_ARR[*]}"

  log "creating remote path $remote:$remote_path"
  "${SSH_ARR[@]}" "$remote" "mkdir -p '$remote_path'"

  log "copying project to $remote:$remote_path"
  rsync -az --delete -e "$ssh_cmd_string" \
    --exclude 'data/postgres/*' --exclude 'run/*' --exclude 'logs/*' \
    "$PROJECT_ROOT/" "$remote:$remote_path/"

  log "starting WireGuard on $loc"
  "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && sudo ./scripts/apply-wireguard.sh '$loc'"

  if [[ "${INSTALL_FIREWALL_DURING_DEPLOY:-false}" == "true" ]]; then
    log "applying nftables on $loc"
    "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && sudo ./scripts/install-nftables.sh '$loc'"
  else
    echo "Firewall not applied automatically. Run after SSH access is verified: sudo ./scripts/install-nftables.sh $loc"
  fi

  log "starting containers on $loc"
  "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && ./scripts/node-compose.sh '$loc' up -d --build"
done

log "deployment pass complete. Run ./scripts/healthcheck.sh on every node."
