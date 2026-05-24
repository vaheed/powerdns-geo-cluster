#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
uri="${1:-}"
[[ -n "$uri" ]] || fatal "usage: $0 s3://bucket/prefix/file.sql.gz.gpg"
loc="${LOCATION_NAME:-eu-ams}"
load_env "$loc"
[[ "$LOCATION_ROLE" == "primary" ]] || fatal "restore must be run on the primary"
need aws
need gpg
need gunzip
need docker
[[ -f "$BACKUP_GPG_PASSPHRASE_FILE" ]] || fatal "missing backup passphrase file"

work="$PROJECT_ROOT/run/restore/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$work"
enc="$work/backup.sql.gz.gpg"
gz="$work/backup.sql.gz"
sql="$work/backup.sql"

aws_args=(s3 cp "$uri" "$enc" --region "$S3_REGION")
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
aws "${aws_args[@]}"

gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$gz" -d "$enc"
gunzip -c "$gz" > "$sql"

echo "This will replace PowerDNS records in PostgreSQL on $LOCATION_NAME. Type RESTORE to continue:"
read -r confirm
[[ "$confirm" == "RESTORE" ]] || fatal "restore cancelled"

./scripts/node-compose.sh "$LOCATION_NAME" stop pdns
cat "$sql" | docker exec -i "pdns-postgres-$LOCATION_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1
./scripts/node-compose.sh "$LOCATION_NAME" start pdns
log "restore complete. Reinitialize standbys if replication diverged: scripts/sync-zones.sh --reinit-standby"
