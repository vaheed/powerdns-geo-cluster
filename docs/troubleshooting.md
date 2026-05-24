# Troubleshooting

## First checks

1. `./scripts/cluster.sh validate`
2. `./scripts/cluster.sh check eu-ams`
3. `./scripts/cluster.sh replication check eu-ams`

## Replication issues

- Verify WireGuard is up on all nodes.
- Verify standby can reach primary WG IP/public fallback.
- Confirm secrets files exist under `secrets/`.

## Restore issues

- Ensure restore runs on primary location only.
- Verify S3 URI and GPG passphrase file are correct.
