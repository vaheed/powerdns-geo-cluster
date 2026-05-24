# Backup and Restore

## Backup

```bash
./scripts/cluster.sh backup eu-ams
```

- Runs on primary only.
- Produces encrypted backup and uploads to S3.

## Restore

```bash
./scripts/cluster.sh restore s3://bucket/prefix/file.sql.gz.gpg eu-ams
```

- Restore requires explicit `RESTORE` confirmation.
- Restore should be done on primary, then replication must be checked.
