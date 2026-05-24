#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mode="${1:---check}"
loc="${LOCATION_NAME:-}"
if [[ -z "$loc" ]]; then
  for f in "$PROJECT_ROOT/config/locations"/*.env; do loc="$(basename "$f" .env)"; break; done
fi
load_env "$loc"

cid="pdns-postgres-$LOCATION_NAME"
case "$mode" in
  --check)
    if [[ "$LOCATION_ROLE" == "primary" ]]; then
      docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
        "select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn from pg_stat_replication order by application_name;"
    else
      docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
        "select pg_is_in_recovery() as standby, status, sender_host, sender_port, latest_end_lsn, now() - pg_last_xact_replay_timestamp() as replay_lag from pg_stat_wal_receiver;"
    fi
    ;;
  --reinit-standby)
    [[ "$LOCATION_ROLE" == "standby" ]] || fatal "--reinit-standby must be run on a standby"
    ./scripts/node-compose.sh "$LOCATION_NAME" down
    rm -rf "$PROJECT_ROOT/data/postgres/$LOCATION_NAME"
    ./scripts/node-compose.sh "$LOCATION_NAME" up -d --build postgres
    ;;
  *) fatal "usage: $0 --check|--reinit-standby" ;;
esac
