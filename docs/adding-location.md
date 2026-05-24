# Adding a location

## Example

Add Frankfurt as `eu-fra`:

```bash
./scripts/bootstrap-location.sh eu-fra 203.0.113.44 10.90.0.40 EU root 22
```

The script is idempotent. If the location already exists, it refreshes generated configuration.

## What the script changes

It creates or updates:

```text
config/locations/eu-fra.env
docker-compose.eu-fra.yml
config/generated/eu-fra/wireguard/wg-pdns.conf
config/generated/eu-fra/pdns/pdns.conf
config/generated/eu-fra/db/postgresql.conf
config/generated/eu-fra/db/pg_hba.conf
config/generated/cluster-peer-public-cidrs
cluster-inventory.yml
```

## Apply on the primary

After adding a node, reload the primary WireGuard configuration and firewall:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
sudo ./scripts/install-nftables.sh eu-ams
./scripts/node-compose.sh eu-ams restart postgres
```

Restarting PostgreSQL is needed only when `pg_hba.conf` changes and a reload is not enough in your operational policy. A reload normally suffices:

```bash
docker exec pdns-postgres-eu-ams pg_ctl reload -D /var/lib/postgresql/data/pgdata
```

## Start the new node

Copy the repository to the new node:

```bash
./scripts/push-node.sh eu-fra
```

On the new node:

```bash
sudo ./scripts/apply-wireguard.sh eu-fra
sudo ./scripts/install-nftables.sh eu-fra
./scripts/node-compose.sh eu-fra up -d --build
```

The first boot initializes PostgreSQL by streaming a base backup from the primary.

## Remove a location safely

1. Remove the location's NS record at the parent zone and wait at least the parent-zone TTL.
2. Stop containers on the removed node.
3. Remove its WireGuard peer from all remaining generated configs.
4. Remove its public `/32` from `config/generated/cluster-peer-public-cidrs`.
5. Drop the PostgreSQL replication slot on the primary:

```sql
SELECT pg_drop_replication_slot('eu_ams_LOCATION');
```

6. Re-render configs and re-apply nftables.
