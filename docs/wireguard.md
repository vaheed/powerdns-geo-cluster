# WireGuard sync network

## Purpose

WireGuard is the preferred replication network. PostgreSQL streaming replication should use the WireGuard IP first and the public primary IP only as a fallback.

Default IP plan:

| Location | Role | WireGuard IP |
|---|---:|---:|
| eu-ams | primary | 10.90.0.10 |
| us-nyc | standby | 10.90.0.20 |
| as-teh | standby | 10.90.0.30 |

## Generate configuration

Run on the first machine:

```bash
./scripts/setup-cluster.sh
```

The script generates:

```text
config/generated/eu-ams/wireguard/wg-pdns.conf
config/generated/us-nyc/wireguard/wg-pdns.conf
config/generated/as-teh/wireguard/wg-pdns.conf
```

## Install on a node

On the matching node:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
```

Use the current node's location name.

## Verify

```bash
sudo wg show wg-pdns
ping -c 3 10.90.0.10
```

From standbys, PostgreSQL should connect to `10.90.0.10` during normal operation.

## Failure behavior

When WireGuard is down, standby PostgreSQL reconnects through the next host in `POSTGRES_PRIMARY_HOSTS`, normally the primary public IP. The fallback is protected by nftables, `pg_hba.conf`, and PostgreSQL TLS.

## Adding a peer

Use:

```bash
./scripts/bootstrap-location.sh --interactive
```

Then re-apply WireGuard on every existing node because each WireGuard node needs the new peer block.
