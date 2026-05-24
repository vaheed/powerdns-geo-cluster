# Operations guide

## First machine setup

Run all cluster generation from the first machine, normally `eu-ams`.

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin wireguard wireguard-tools nftables openssl jq curl dnsutils awscli gnupg rsync
cd /opt
unzip powerdns-geo-cluster.zip
cd powerdns-geo-cluster
cp env.example .env
./scripts/setup-cluster.sh
```

The setup script asks for:

- public DNS IP for every node
- WireGuard IP for every node
- SSH user and port
- management CIDRs
- MaxMind account and license key
- S3 bucket, region, and encryption mode

After the script completes, copy the project directory to every standby node:

```bash
./scripts/push-node.sh us-nyc
./scripts/push-node.sh as-teh
```

Password SSH is intentionally not automated by default. Use SSH keys. If you must use password SSH for a temporary bootstrap, install `sshpass` yourself and remove password auth afterward.

## Start WireGuard

On each node:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
sudo ./scripts/apply-wireguard.sh us-nyc
sudo ./scripts/apply-wireguard.sh as-teh
```

Use the location that matches the current host.

Check tunnel state:

```bash
sudo wg show wg-pdns
ping -c 3 10.90.0.10
```

## Start containers

Start the primary first:

```bash
./scripts/node-compose.sh eu-ams up -d --build
```

Wait until PostgreSQL and PowerDNS are healthy:

```bash
./scripts/healthcheck.sh eu-ams
```

Then start standbys:

```bash
./scripts/node-compose.sh us-nyc up -d --build
./scripts/node-compose.sh as-teh up -d --build
```

Each standby performs `pg_basebackup` on first boot. It will retry until the primary is reachable.

## Download MaxMind GeoLite2

MaxMind credentials are required. They are not bundled.

```bash
./scripts/download-geoip.sh eu-ams
```

Copy `data/geoip/` to the other nodes or run the same command on each node. Restart PowerDNS after the first database download:

```bash
./scripts/node-compose.sh eu-ams restart pdns
```

## Add a domain

Always run write commands on the primary.

```bash
./bin/geo-dnsctl add-domain example.com
./bin/geo-dnsctl add-record example.com @ A 203.0.113.20 --ttl 300
./bin/geo-dnsctl add-record example.com mail A 203.0.113.25 --ttl 300
./bin/geo-dnsctl add-record example.com @ MX '10 mail.example.com.' --ttl 300
```

## Add a GEO record

```bash
./bin/geo-dnsctl add-geo-record example.com www \
  --eu 203.0.113.10 \
  --na 198.51.100.10 \
  --asia 192.0.2.10 \
  --default 203.0.113.100 \
  --ttl 60
```

## Validate GEO behavior

```bash
./tests/test-geo-routing.sh eu-ams www.example-geo.test EU_PUBLIC_IP
```

Manual ECS tests:

```bash
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=80.101.1.1/32 +short
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=8.8.8.8/32 +short
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=202.12.27.33/32 +short
```

## Check replication

On the primary:

```bash
./scripts/sync-zones.sh --check
```

On a standby:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --check
```

## Recover a failed standby

If a standby falls too far behind and its replication slot no longer has required WAL:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --reinit-standby
```

This deletes the standby's local PostgreSQL data and takes a fresh base backup from the primary. Do not run this on the primary.

## Backups

Backups are encrypted locally with GPG symmetric AES256 before upload to S3. The S3 upload also requests server-side encryption, either SSE-KMS or SSE-S3.

```bash
./scripts/backup.sh
```

The local encrypted backup is removed by default after upload. Set `KEEP_LOCAL_BACKUPS=true` only if the local disk is protected and monitored.

## Restore

Restore only to the primary:

```bash
./scripts/restore.sh s3://BUCKET/PREFIX/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

After a major restore, reinitialize standbys to guarantee they follow the restored primary state.

## Optional one-pass remote deployment

After `setup-cluster.sh` generates all files, you can use the interactive deployment helper from the first machine:

```bash
./scripts/deploy-cluster.sh
```

It asks before touching each node. For each accepted node it copies the repository to `/opt/powerdns-geo-cluster`, applies WireGuard, optionally applies nftables if `INSTALL_FIREWALL_DURING_DEPLOY=true`, and starts the node's Compose stack.

Key-based SSH is preferred:

```env
SSH_USER=root
SSH_PORT=22
SSH_KEY=/root/.ssh/pdns-cluster-ed25519
SSH_PASSWORD=
```

Temporary password bootstrap is supported only when `sshpass` is installed on the first machine:

```env
SSH_USER=root
SSH_PORT=22
SSH_KEY=
SSH_PASSWORD=TEMPORARY_PASSWORD
```

Remove password SSH after bootstrap.
