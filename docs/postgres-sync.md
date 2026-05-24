# PostgreSQL Replication

## Check replication status

```bash
./scripts/cluster.sh replication check eu-ams
./scripts/cluster.sh replication check us-nyc
```

## Lag policy

- Keep standby lag low and alert using monitoring stack.
- Use failover command only when standby is healthy.
