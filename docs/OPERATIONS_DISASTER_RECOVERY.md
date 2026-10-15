# Chatify Operations, Backup and Disaster Recovery

This runbook provides repeatable MongoDB archive and restore commands. It does not create a backup provider, schedule a hosted job, encrypt off-site copies, or prove that a restore works against your production infrastructure.

## Backup

Requirements: MongoDB Database Tools, access to the intended database, and a private persistent directory with sufficient disk space.

```bash
export MONGODB_URI='(load from your secret manager; do not paste into shell history)'
export BACKUP_DIR='/secure/persistent/chatify-backups'
export RETENTION_DAYS=14
bash server/scripts/backup-mongodb.sh
```

The script uses `mongodump --archive --gzip`, restrictive file permissions, UTC timestamped filenames and SHA-256 checksums. It never prints the database URI. Backups must be copied to a separate encrypted/off-site location by your infrastructure job; local disk alone is not disaster recovery.

## Restore drill (non-production only)

1. Create a separate empty staging/recovery database and verify the target URI points to that database.
2. Obtain the backup and its checksum from trusted storage.
3. Run the restore only after explicitly confirming the target is non-production:

```bash
export ARCHIVE='/secure/persistent/chatify-backups/chatify-YYYYMMDDTHHMMSSZ.archive.gz'
export RESTORE_TARGET_URI='(staging database URI from your secret manager)'
export RESTORE_TARGET_IS_NON_PRODUCTION=YES
export CONFIRM_RESTORE=YES
bash server/scripts/restore-mongodb.sh
```

The restore script deliberately does not use `--drop` and does not read `MONGODB_URI`. Restore into a fresh target, never point this command at the production database. The operator must validate indexes, user/business/payment record counts, auth, chat send/read, file URLs, webhook idempotency and health checks before approving a cutover.

## Operational controls required before launch

- Configure a persistent, private `MONGODB_URI` and a high-entropy `JWT_SECRET` in the hosting secret store.
- Keep HTTPS-only public API and restrict CORS to known web origins.
- Configure provider callbacks and verify signatures, idempotency, expected amount/currency and tenant association before confirming payment.
- Alert on repeated 5xx responses, database disconnects, failed email delivery, payment webhook failures, high latency and backup job failures.
- Run a scheduled backup and record its timestamp/checksum; periodically restore it into isolated staging and record recovery time and data-loss window.
- Store backups encrypted off-site with access logging and retention controls; restrict restore privileges separately from application credentials.
- Publish privacy/terms, data retention, account export/deletion, abuse-report handling and incident-response contacts before public launch.
- Never call a backup successful merely because the script exited zero; require archive validation and a tested restore drill.

## Remaining infrastructure-owned work

The repository scripts are building blocks. Hosting-level cron/scheduler setup, off-site encryption and storage, alert routing, uptime monitoring, recovery-point objective (RPO), recovery-time objective (RTO), and an observed restore drill require deployment infrastructure and credentials that are not present in the repository.
