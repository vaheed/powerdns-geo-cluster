# Failover

## Promote standby

```bash
./scripts/cluster.sh failover us-nyc
```

## Validate

```bash
./scripts/cluster.sh replication check us-nyc
./scripts/cluster.sh check us-nyc
```

## After failover

- Reconfigure old primary as standby and rejoin replication.
- Update traffic routing and operational runbooks.
