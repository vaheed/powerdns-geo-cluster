#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${LOCATION_NAME:-eu-ams}"
load_env "$loc"
[[ "$LOCATION_ROLE" == "primary" ]] || fatal "run backups on the primary only"
need docker
need gzip
need gpg
need aws

ts="$(date -u +%Y%m%dT%H%M%SZ)"
work="$PROJECT_ROOT/${BACKUP_TMP_DIR:-run/backups/tmp}"
mkdir -p "$work"
plain="$work/pdns-${LOCATION_NAME}-${ts}.sql"
gz="$plain.gz"
enc="$gz.gpg"
sha="$enc.sha256"

[[ -f "$BACKUP_GPG_PASSPHRASE_FILE" ]] || fatal "missing BACKUP_GPG_PASSPHRASE_FILE=$BACKUP_GPG_PASSPHRASE_FILE"

docker exec "pdns-postgres-$LOCATION_NAME" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=plain --clean --if-exists --no-owner --no-privileges > "$plain"
gzip -9 "$plain"
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" \
  --symmetric --cipher-algo AES256 -o "$enc" "$gz"
sha256sum "$enc" > "$sha"

s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${LOCATION_NAME}/$(basename "$enc")"
aws_args=(s3 cp "$enc" "$s3_uri" --region "$S3_REGION")
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
if [[ "${S3_SSE_MODE:-aws:kms}" == "aws:kms" ]]; then
  aws_args+=(--sse aws:kms --sse-kms-key-id "$S3_KMS_KEY_ID")
else
  aws_args+=(--sse AES256)
fi
aws "${aws_args[@]}"
aws s3 cp "$sha" "$s3_uri.sha256" --region "$S3_REGION" ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"}

if [[ "${KEEP_LOCAL_BACKUPS:-false}" != "true" ]]; then
  rm -f "$gz" "$enc" "$sha"
fi
log "backup uploaded: $s3_uri"
