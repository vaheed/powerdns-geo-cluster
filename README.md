# powerdns-geo-cluster

Production-oriented PowerDNS Authoritative GEO DNS cluster with three starting locations:

- `eu-ams`, Amsterdam, primary writer
- `us-nyc`, New York, standby reader
- `as-teh`, Tehran, standby reader

The deployment uses Docker Compose, PowerDNS Authoritative, PostgreSQL streaming replication, WireGuard for the normal replication path, restricted public-IP PostgreSQL fallback, encrypted S3 backups, nftables, and a small CLI named `geo-dnsctl`.

## Supported operating model

Write DNS data only on the primary node. The primary PostgreSQL database streams WAL to the standby locations. Each location runs its own PowerDNS Authoritative service and answers public DNS on UDP/TCP 53 from its local database copy.

Normal sync path:

```text
standby PostgreSQL -> WireGuard tunnel -> primary PostgreSQL
```

Fallback sync path:

```text
standby PostgreSQL -> primary public IP TCP/5432 -> primary PostgreSQL
```

The fallback is not open to the internet. nftables and `pg_hba.conf` restrict it to known node public IP addresses only. PostgreSQL TLS is enabled for both WireGuard and direct-public replication.

## Fast start

Install dependencies on all nodes first:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin wireguard wireguard-tools nftables openssl jq curl dnsutils awscli gnupg rsync
```

On the first machine, clone or copy this repository, then run:

```bash
cd powerdns-geo-cluster
cp env.example .env
./scripts/setup-cluster.sh
```

The setup script asks for the primary node, standby nodes, public IPs, WireGuard IPs, SSH information, MaxMind credentials, and S3 backup settings. It generates all per-node files under `config/generated/`, `config/locations/`, and `secrets/`.

Start the primary:

```bash
./scripts/node-compose.sh eu-ams up -d --build
```

Start the standby nodes after WireGuard is up and the generated files are copied to each node:

```bash
./scripts/node-compose.sh us-nyc up -d --build
./scripts/node-compose.sh as-teh up -d --build
```

Load the example domain on the primary:

```bash
./bin/geo-dnsctl add-domain example-geo.test
./bin/geo-dnsctl add-geo-record example-geo.test www \
  --eu 203.0.113.10 \
  --na 198.51.100.10 \
  --asia 192.0.2.10 \
  --default 203.0.113.100 \
  --ttl 60
```

Validate:

```bash
./bin/geo-dnsctl validate
./scripts/healthcheck.sh
./scripts/sync-zones.sh --check
./tests/test-geo-routing.sh
```

Enable firewall:

```bash
sudo ./scripts/install-nftables.sh eu-ams
sudo ./scripts/install-nftables.sh us-nyc
sudo ./scripts/install-nftables.sh as-teh
```

Back up to encrypted S3:

```bash
./scripts/backup.sh
```

Restore to the primary from S3:

```bash
./scripts/restore.sh s3://YOUR_BUCKET/powerdns-geo-cluster/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

## Current documentation references

This project follows these supported product behaviors:

- PowerDNS Authoritative PostgreSQL backend is read-write capable through the API.
- Lua records support GEO decisions through the GeoIP backend and EDNS Client Subnet.
- The PowerDNS built-in webserver/API should be bound and ACL-restricted.
- PostgreSQL streaming replication supports primary/standby operation; `primary_conninfo` uses libpq connection parameters.
- AWS CLI `s3 cp` supports server-side encryption modes including AES256 and `aws:kms`.

See `docs/` for the detailed production procedure.
