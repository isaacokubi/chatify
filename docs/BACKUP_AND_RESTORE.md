# Backup and Restore

The detailed, executable runbook is [OPERATIONS_DISASTER_RECOVERY.md](OPERATIONS_DISASTER_RECOVERY.md). This document is the operational entry point.

## Backup requirements

- Use MongoDB Database Tools and the repository backup script `server/scripts/backup-mongodb.sh`.
- Supply the database URI through a private secret manager, never shell history or logs.
- Use a persistent private backup directory with restrictive permissions.
- Verify archive checksum and size.
- Copy archives to encrypted off-site storage using infrastructure-owned credentials.
- Apply retention and access logging.

## Restore requirements

- Restore only into a separately provisioned, empty, non-production recovery database.
- Use `server/scripts/restore-mongodb.sh` and its explicit non-production confirmation guards.
- Do not use `--drop` or target the production application URI.
- Verify indexes, user/workspace/payment counts, authentication, messaging, file URLs and service health after restore.
- Record recovery time, restore point and validation evidence.

## Acceptance

A backup job succeeding is not a restore test. Production launch requires a witnessed restore drill, checksum validation, documented RPO/RTO, encrypted off-site retention and named recovery operators.
