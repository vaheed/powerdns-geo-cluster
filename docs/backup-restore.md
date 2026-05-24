# Encrypted S3 backup and restore

## Backup design

Backups are created on the primary node only. The process is:

1. Run `pg_dump` from the PostgreSQL container.
2. Compress with gzip.
3. Encrypt client-side with GPG symmetric AES256.
4. Upload to S3 with server-side encryption enabled.
5. Remove local encrypted files unless `KEEP_LOCAL_BACKUPS=true`.

This gives encryption before the object reaches S3 and encryption at rest inside S3.

## Required environment

```env
S3_BUCKET=your-bucket
S3_PREFIX=powerdns-geo-cluster
S3_REGION=eu-west-1
S3_SSE_MODE=aws:kms
S3_KMS_KEY_ID=alias/pdns-backups
BACKUP_GPG_PASSPHRASE_FILE=./secrets/backup-gpg-passphrase
```

For S3-compatible storage, set:

```env
S3_ENDPOINT_URL=https://s3.example.net
S3_SSE_MODE=AES256
```

## AWS IAM minimum

The backup identity needs:

- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` for the target bucket/prefix
- `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` when SSE-KMS is used

## Run backup

```bash
./scripts/backup.sh
```

## Restore

```bash
./scripts/restore.sh s3://bucket/prefix/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

The script requires typing `RESTORE` before it applies the SQL. After a full restore, reinitialize standbys if there is any sign of replication divergence.
