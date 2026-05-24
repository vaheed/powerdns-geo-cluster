# Security guide

## Exposed ports

Public internet:

- UDP 53
- TCP 53
- UDP WireGuard port, default 51820
- TCP 5432 only from known cluster peer public IPs, for fallback replication

Management only:

- SSH
- PowerDNS API, default bound to `127.0.0.1`

The PowerDNS API is enabled because `geo-dnsctl` uses it, but it must not be exposed publicly.

## nftables

Install nftables after confirming your management CIDRs are correct:

```bash
sudo ./scripts/install-nftables.sh eu-ams
```

The policy is default deny. Denied packets are logged with the prefix `pdns_geo_drop`.

## PostgreSQL fallback over public IPs

The fallback path is not a general database listener. It is restricted in three layers:

1. Docker binds PostgreSQL only to the node public IP and WireGuard IP.
2. nftables allows TCP 5432 only from cluster peer public IPs and the WireGuard CIDR.
3. `pg_hba.conf` allows replication only from the WireGuard CIDR and explicit peer public `/32` addresses.

PostgreSQL TLS is enabled and standbys verify the generated cluster CA.

## Secrets

Protect these paths:

```text
.env
secrets/
config/locations/*.env
config/generated/*/pdns/pdns.conf
```

They contain API keys, database passwords, WireGuard private keys, and backup encryption material.

## DDoS notes

nftables rate limiting is not DDoS protection. For production authoritative DNS traffic, use anycast with upstream filtering, a DNS DDoS provider, or provider-level ACL/scrubbing. DNS UDP amplification exposure should be monitored continuously.

## AXFR and TSIG

AXFR is disabled because database replication is the sync model. If you later enable AXFR for external secondaries, use TSIG and a dedicated allow-list. Do not enable unauthenticated AXFR on public interfaces.
