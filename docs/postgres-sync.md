# PostgreSQL synchronization

## Model

The cluster uses one PostgreSQL writer and multiple hot standbys.

- `eu-ams` is the initial primary.
- `us-nyc` and `as-teh` are read-only standbys.
- PowerDNS reads local PostgreSQL in every location.
- `geo-dnsctl` writes only through the primary PowerDNS API.

## Standby initialization

On first startup, a standby runs `pg_basebackup` against the primary and creates a physical replication slot. The slot name is stored in `config/locations/LOCATION.env`.

Example:

```env
REPLICATION_SLOT_NAME=eu_ams_us_nyc
POSTGRES_PRIMARY_HOSTS=10.90.0.10,PRIMARY_PUBLIC_IP
POSTGRES_PRIMARY_PORTS=5432,5432
POSTGRES_SYNC_SSLMODE=verify-ca
```

## Fallback host order

The host list is ordered. WireGuard comes first:

```text
10.90.0.10,PRIMARY_PUBLIC_IP
```

If the tunnel is healthy, replication uses WireGuard. If WireGuard fails, libpq can connect to the primary public IP. The public fallback must remain restricted to known node public `/32` addresses.

## Conflict avoidance

There is no multi-master mode. Do not promote or write to standby nodes unless you are executing a disaster-recovery runbook. This prevents split-brain records.

## Monitoring

Primary:

```bash
./scripts/sync-zones.sh --check
```

Standby:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --check
```

## Rebuild a standby

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --reinit-standby
```

This deletes the standby's local database copy and creates a fresh base backup.
