# Security

## Controls in place

- PostgreSQL backend from PowerDNS uses TLS with `sslmode=verify-ca`.
- CA cert is mounted into `pdns` containers.
- PostgreSQL local auth is `scram-sha-256`.
- Replication password is read from file secret (`secrets/postgres-replication-password`).
- WireGuard private keys are file-based under `secrets/wireguard/*.private`.
- Firewall rules are applied with `./scripts/cluster.sh firewall apply <location>`.

## Certificate lifecycle

- Generate all certs: `./scripts/cluster.sh tls generate`
- Renew leaf certs: regenerate and redeploy, then restart location services.
- Expose cert-expiry metrics via monitoring textfile collector (if enabled).
