# Architecture

## Topology

```mermaid
flowchart TD
  R[Resolvers] --> P1[PowerDNS eu-ams]
  R --> P2[PowerDNS us-nyc]
  R --> P3[PowerDNS as-teh]

  P1 --> DB1[(PostgreSQL primary)]
  P2 --> DB2[(PostgreSQL standby)]
  P3 --> DB3[(PostgreSQL standby)]

  DB1 -->|WAL over WireGuard| DB2
  DB1 -->|WAL over WireGuard| DB3
  DB1 -.->|TLS fallback over public 5432| DB2
  DB1 -.->|TLS fallback over public 5432| DB3
```

## How it works

1. DNS changes are written on primary only.
2. PostgreSQL streaming replication distributes state to standbys.
3. Each location answers DNS from local DB.

## Why it is stable

- Single writer avoids conflict/split-brain writes.
- Local read copies keep latency low per region.
- WireGuard-first replication with TLS fallback keeps sync resilient.

## Operator model

All setup and operations are done with:

`./scripts/cluster.sh`
