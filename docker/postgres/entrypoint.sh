#!/usr/bin/env bash
set -Eeuo pipefail

: "${LOCATION_ROLE:=primary}"
: "${PGDATA:=/var/lib/postgresql/data/pgdata}"

prepare_tls() {
  if [[ -d /tls && -f /tls/server.crt && -f /tls/server.key && -f /tls/ca.crt ]]; then
    mkdir -p "$PGDATA/tls"
    cp /tls/server.crt /tls/server.key /tls/ca.crt "$PGDATA/tls/"
    chown -R postgres:postgres "$PGDATA/tls"
    chmod 700 "$PGDATA/tls"
    chmod 600 "$PGDATA/tls/server.key"
    chmod 644 "$PGDATA/tls/server.crt" "$PGDATA/tls/ca.crt"
  fi
}

prepare_tls

if [[ "$LOCATION_ROLE" == "standby" ]]; then
  [[ -n "${POSTGRES_PRIMARY_HOSTS:-}" ]] || { echo "POSTGRES_PRIMARY_HOSTS is required on standby nodes" >&2; exit 1; }
  [[ -n "${REPLICATION_SLOT_NAME:-}" ]] || { echo "REPLICATION_SLOT_NAME is required on standby nodes" >&2; exit 1; }
  [[ -f "${POSTGRES_REPLICATION_PASSWORD_FILE:-}" ]] || { echo "POSTGRES_REPLICATION_PASSWORD_FILE is required" >&2; exit 1; }

  if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
    echo "Initializing standby from primary via pg_basebackup"
    rm -rf "$PGDATA"
    mkdir -p "$PGDATA"
    chown -R postgres:postgres "$(dirname "$PGDATA")"
    chmod 700 "$PGDATA"

    conninfo="host=${POSTGRES_PRIMARY_HOSTS} port=${POSTGRES_PRIMARY_PORTS:-5432} user=${POSTGRES_REPLICATION_USER} dbname=replication application_name=${LOCATION_NAME:-standby} sslmode=${POSTGRES_SYNC_SSLMODE:-verify-ca} sslrootcert=/tls/ca.crt connect_timeout=5 target_session_attrs=read-write"

    PGPASSWORD="$(cat "$POSTGRES_REPLICATION_PASSWORD_FILE")"
    export PGPASSWORD
    sleep_s=2
    until gosu postgres pg_basebackup -D "$PGDATA" -X stream -R -C -S "$REPLICATION_SLOT_NAME" -d "$conninfo"; do
      echo "pg_basebackup failed; retrying in ${sleep_s} seconds" >&2
      sleep "$sleep_s"
      sleep_s=$(( sleep_s < 60 ? sleep_s * 2 : 60 ))
    done
    unset PGPASSWORD

    echo "primary_conninfo = '$conninfo password=$(cat "$POSTGRES_REPLICATION_PASSWORD_FILE")'" >> "$PGDATA/postgresql.auto.conf"
    echo "primary_slot_name = '$REPLICATION_SLOT_NAME'" >> "$PGDATA/postgresql.auto.conf"
    chown -R postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    prepare_tls
  fi
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"
