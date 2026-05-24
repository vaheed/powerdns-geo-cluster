# Operations

## One script for everything

Use `./scripts/cluster.sh` for all tasks.

## Initial setup

1. `sudo ./scripts/cluster.sh install-deps`
2. `cp env.example .env`
3. `./scripts/cluster.sh init`
4. `sudo ./scripts/cluster.sh wireguard apply eu-ams`
5. `sudo ./scripts/cluster.sh wireguard apply us-nyc`
6. `sudo ./scripts/cluster.sh wireguard apply as-teh`
7. `./scripts/cluster.sh up eu-ams`
8. `./scripts/cluster.sh up us-nyc`
9. `./scripts/cluster.sh up as-teh`
10. `./scripts/cluster.sh check eu-ams`
11. `./scripts/cluster.sh replication check eu-ams`
12. `./scripts/cluster.sh validate`

## Daily operations

1. Start/stop: `up`, `down`, `restart`, `status`
2. Monitoring: `monitoring on/off <location>`
3. Backup: `backup <location>`
4. Restore: `restore <s3-uri> <location>`
5. Failover: `failover <standby-location>`
6. Deploy to nodes: `deploy`

## Helpful command

`./scripts/cluster.sh --help`
