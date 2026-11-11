# Chatify Operations Runbook

## Routine health checks

1. Confirm the API deployment is running the intended commit SHA.
2. Check the service health/readiness endpoints exposed by that build.
3. Confirm MongoDB Atlas connectivity and connection-pool health.
4. Review structured API errors, latency and rate-limit metrics.
5. Verify the email, media, FCM and payment adapters are configured or deliberately disabled.
6. Confirm the most recent backup timestamp/checksum and backup-job outcome.
7. Review failed payment callbacks, pending/review-required transactions and reconciliation queues.
8. Review school/business membership changes and platform-admin actions.

## Incident response

- Preserve relevant logs and timestamps while redacting authorization headers, tokens, callback path secrets, student data and customer personal data.
- Determine affected tenants and records before taking action.
- Revoke compromised sessions/credentials through the supported controls.
- Do not manually mark payment records successful to clear an incident.
- For data corruption, stop affected writes and restore only into isolated recovery first.
- Notify the responsible platform operator and affected tenant contacts according to the approved incident plan.
- Record impact, timeline, root cause, corrective action and follow-up owner.

## Payment incidents

- Keep an unknown initiation/callback result pending or review-required.
- Verify provider reference, tenant, amount, currency, payer and callback authenticity.
- Check idempotency records before retrying.
- Reconcile with the provider's transaction query; do not rely on screenshots or client status.
- Never move funds between platform and merchant accounts to work around a provider limitation.

## School privacy incidents

- Restrict access to the affected workspace or records where necessary.
- Preserve audit evidence without copying children's records into tickets or chat.
- Follow the approved controller/processor and breach-notification process.
- Do not resume real student data processing until the school/platform owner has approved the remediation.

## Recovery and rollback

Use [Backup and Restore](BACKUP_AND_RESTORE.md) and [Deployment](DEPLOYMENT.md). Keep rollback artifacts and the exact release SHA. Do not roll back database migrations blindly.

## Operational evidence

Maintain a dated record of health checks, backup/restore drills, provider callbacks, alert tests, incidents, on-call contacts and release approvals. Monitoring, alert delivery and off-site backups are infrastructure-owned and must be proven in the target deployment.


## School receipt-index migration

The school fee and donation receipt indexes must enforce uniqueness only for non-empty receipt values. For an existing deployment, take a verified backup, confirm the exact target database, then run `node scripts/migrate-school-receipt-indexes.mjs` from `server/` with `MONGODB_URI`, `CHATIFY_EXPECTED_DATABASE_NAME` matching the URI database exactly, and `CHATIFY_CONFIRM_SCHOOL_RECEIPT_INDEX_MIGRATION=YES`. The script drops only the known obsolete school receipt/checkout index names and creates the partial unique replacements. It never deletes or rewrites payment records. If a duplicate actual receipt prevents index creation, stop and reconcile the records; do not disable uniqueness. Verify both new index names with `listIndexes()` before accepting school fee traffic.
