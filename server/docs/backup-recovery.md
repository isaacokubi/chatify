# Chatify backup and recovery operations

## Automated encrypted off-site backup

The workflow `.github/workflows/encrypted-offsite-backup.yml` runs daily at 02:30 UTC and can also be started manually. It encrypts the MongoDB dump with `age` before writing it to disk and uploads the ciphertext plus SHA-256 checksum to S3.

Configure these repository Actions secrets before expecting the scheduled workflow to succeed:

- `CHATIFY_BACKUP_MONGODB_URI`: read-only backup identity URI for the production Chatify database.
- `CHATIFY_BACKUP_AGE_RECIPIENT`: age public recipient. Keep the matching private identity offline or in a restricted secret manager.
- `CHATIFY_BACKUP_S3_URI`: private `s3://bucket/prefix` destination.
- `CHATIFY_BACKUP_AWS_ROLE_ARN`: narrowly scoped AWS role ARN trusted for this repository's GitHub OIDC subject.
- `CHATIFY_BACKUP_AWS_REGION`: bucket region.

The role should only write/list objects under the backup prefix; do not use long-lived AWS access keys. Enable S3 versioning, block public access, and configure a lifecycle/retention policy. Consider S3 Object Lock for immutable recovery points. Restrict workflow and secret access to trusted maintainers.

## Recovery drill

Run `.github/workflows/recovery-drill-staging.yml` manually and enter the exact encrypted archive filename plus `RESTORE_TO_STAGING`. Configure these additional secrets:

- `CHATIFY_BACKUP_AGE_IDENTITY`: full age private identity, kept separate from the public recipient.
- `CHATIFY_STAGING_RESTORE_MONGODB_URI`: URI for a separate staging/recovery database, never production.
- `CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION`: set to `YES` only after verifying the target is isolated and non-production.

The workflow verifies the checksum, decrypts on an ephemeral runner, and restores without `--drop`. Afterwards, verify collection/index counts, sign-in, chat history, school and business records, and payment/receipt read-only views. Never test restore by pointing at production.

## Admin backup endpoint

The platform-admin backup endpoints use `CHATIFY_BACKUP_DIR` and `MONGODB_URI` / `MONGO_URL`. Local disk on an ephemeral host is not durable storage; use persistent private storage and the encrypted off-site workflow. Restore is deliberately blocked unless a separate `CHATIFY_RESTORE_TARGET_URI` and `CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION=YES` are configured.

## Limits and monitoring

A green workflow proves that the job completed, not that a disaster-recovery exercise has passed. Record the latest successful backup time, alert on missed runs, periodically run the staging restore, and measure recovery point objective (RPO) and recovery time objective (RTO). The S3 workflow requires repository secrets and AWS OIDC setup before it can run successfully.


## Voice/video calling TURN configuration

The authenticated endpoint `GET /api/calls/ice-servers` returns STUN plus short-lived TURN credentials. For reliable calls across mobile carriers, Wi-Fi routers, and restrictive NATs, deploy a TURN server/provider that supports the coturn REST shared-secret authentication model and configure:

- `CHATIFY_TURN_URLS`: comma-separated `turn:` / `turns:` URLs, including transport options as required.
- `CHATIFY_TURN_SHARED_SECRET`: at least 32 random characters; configure the same secret on the TURN service as its REST shared secret. Never expose this secret in the app or logs.
- `CHATIFY_TURN_CREDENTIAL_TTL_SECONDS`: optional lifetime from 60 to 3600 seconds (default 3600).

The API sends a per-user, expiring username/password pair and disables caching on the response. Without TURN configuration, calls fall back to public STUN and may fail on restrictive networks. Verify call connectivity across two separate mobile networks and Wi-Fi before production release.
