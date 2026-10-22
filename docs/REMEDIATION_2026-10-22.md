# Chatify Remediation Log — 2026-10-22

This file records code changes made directly on `main` after the commercial-readiness audit. It is evidence of repository changes, not a claim that live production infrastructure has been tested.

## Implemented in this pass

### Commission-free payment policy
- Payment totals now default to the full requested amount with zero Chatify commission.
- Business POS charges and their QR payloads explicitly report a zero commission and a zero commission rate.
- The platform-fee collector's compatibility method returns `NOT_APPLICABLE` and never starts a second STK prompt for new sales or school-fee payments.
- The legacy admin fee settings endpoint reports the commission feature as disabled, and saves `enabled=false` and `feeRate=0` even if an older client submits different values.
- Retrying an older payment creates a commission-free payment record and uses the original amount.
- Workspace setup and monthly subscription billing remain the intended Chatify monetization model. Safaricom/provider fees remain separate from Chatify's platform commission.

### Retry-safe messaging and billing
- Added a shared workspace billing gate for the separate Business enterprise, private search, customer statements, SLA, customer portal, reviews, customer imports, and API-key management routes. It applies the configured grace period, preserves grandfathered legacy workspaces, and fails closed if billing settings cannot be read. Public review and API-key catalogue endpoints stop serving locked workspaces, and public marketplace discovery/products omit locked stores; dedicated billing checkout routes remain reachable so owners can pay.
- Core Business operations, POS authorization/customer STK, and school membership routes now use the same strict billing-status calculation as the owner billing endpoint. Invalid subscription dates cannot be reported as active. Public storefront pages, store directory, seller payment-profile lookup, checkout, and enquiries hide locked storefronts; discovery loads grace-period settings once per request instead of querying once per store. Internal billing fields are stripped from public store responses.
- Pending workspace checkout payments are reused only when the currently configured price still matches. If an administrator changes the price while a payment remains pending, checkout returns a conflict instead of silently presenting an old price or creating another STK prompt.
- Added a partial unique index for pending workspace billing payments and duplicate-key recovery, so concurrent checkout requests converge on one pending payment after the index migration is installed. The migration preflights existing duplicates before creating the index.
- Public store-directory results explicitly strip internal billing fields from response objects; billing state is used for visibility decisions only and is not serialized to customers.
- Authenticated organization list/detail/create/update responses now pass through a shared serializer that removes encrypted POS credential material and internal billing idempotency receipts. Generic organization settings updates cannot overwrite the dedicated POS credential field. Regression tests cover both plain objects and Mongoose-style documents.
- Chat message creation accepts a validated client mutation ID. A unique partial index prevents duplicate messages when a client retries after an ambiguous network timeout; a reused ID cannot be applied to a different conversation.
- The Flutter app now stores encrypted outgoing message envelopes in an account-scoped Flutter Secure Storage outbox (up to 50 queued messages per conversation), displays the queued message locally, and retries after the chat socket reconnects. Queue writes fail closed if secure storage is unavailable; no plaintext preferences fallback is used.
- The outbox is at-least-once delivery with server-side deduplication and now exposes per-message retry/discard controls. Multi-device outbox synchronization and broader conflict/recovery tests remain release gates.

### Offline cache privacy
- Private API responses, conversation metadata and message snapshots now use Flutter Secure Storage as the only persistent cache store.
- Legacy plaintext SharedPreferences cache entries are migrated only when secure storage accepts them, then removed; if secure storage is unavailable, private cache writes are skipped rather than copied into browser local storage.

### Payment callback integrity
- A successful Daraja callback must include the expected amount, normalized payer phone, and a valid M-Pesa receipt reference.
- The receipt is persisted on the payment record.
- A sparse unique receipt index is declared and included in the explicit index migration to prevent the same provider receipt being assigned to multiple payment records.
- Retrying a failed/cancelled payment now preserves its workspace setup/subscription type and workspace ID, so a successful retry can actually activate the intended entitlement while remaining commission-free.
- Workspace setup/subscription application now records each stable payment ID atomically on the workspace. If the server crashes after applying the entitlement but before updating the payment marker, a retry repairs the marker without extending the subscription a second time. Zero-priced billing periods use deterministic IDs so repeated checkout requests cannot repeatedly renew the same period.
- Regression tests cover missing receipts, amount/phone mismatches, fee-free defaults, and POS metadata.

### Encrypted backup and restore tooling
- Added `server/scripts/backup-mongodb-encrypted-offsite.sh`: streams `mongodump` through `age` so plaintext archives are not written to disk, checksums the encrypted archive, uploads archive and checksum to an S3 destination, and retains a bounded local copy.
- Added `server/scripts/restore-mongodb-encrypted.sh`: verifies the checksum, decrypts directly into `mongorestore` without a plaintext temporary archive, and requires explicit confirmation of a non-production target. It never uses `--drop`.
- Both restore scripts now refuse a target URI that exactly matches `PRODUCTION_MONGODB_URI` or `MONGODB_URI` when either is present in the environment, without printing credentials. This is an additional guard, not a substitute for independently verifying the target cluster and database.
- The index migration now preflights the candidate unique indexes for duplicate message mutation IDs, notification deduplication keys, and M-Pesa provider receipts before creating any indexes. If conflicts exist, it reports bounded examples and exits before applying indexes.
- Added `server/scripts/test-restore-safety.sh`; CI syntax-checks the scripts and tests that both restore paths reject matching configured production URIs without leaking them in error output. The backup/restore tooling has not been run against production, scheduled, or configured with the owner's backup recipient, AWS credentials, S3 destination, or retention lifecycle policy.

### Existing CI and reliability work
- API health readiness reports database disconnection as HTTP 503 and now reports the release as `unknown` when deployment metadata is absent, rather than falsely implying the `main` branch is the deployed release.
- A regression test checks the Sparks route is mounted and authenticated rather than returning a false endpoint-not-found response.
- The Spark feed index is included in the non-destructive index migration.
- Notification retry backoff and malformed server syntax issues were repaired in the preceding implementation pass.
- CI includes backend tests, syntax/lint checks, high-severity dependency audit, Flutter analysis/tests, web build, Android debug build, and backup-script shell validation.

## Production steps still requiring operator access

The repository cannot safely complete these without the owner's provider accounts, deployment secrets, production configuration, or isolated infrastructure:

1. **Run the index migration** in the intended production environment only after confirming backups and checking the new receipt index for conflicts. Never point test commands at production.
2. **Verify live M-Pesa end-to-end** with authorized Daraja credentials, real callback delivery, refund/reversal procedures, and reconciliation. A successful STK initiation is not proof of payment.
3. **Complete the encryption protocol** using a reviewed ratcheting design with forward secrecy, verified identity keys, encrypted attachments and Memory Cards, and user-approved device transfer/recovery. The current client-side text encryption must not be advertised as a fully audited secure-messenger protocol.
4. **Complete offline synchronization** with a local database, multi-device outbox synchronization, explicit retry/cancel controls, conflict/deletion synchronization, and broader recovery tests. The current encrypted outbox is device-local and must never queue or infer a successful payment while offline.
5. **Deploy distributed real-time infrastructure** (shared Socket.IO adapter/presence and shared rate-limit state), durable background workers, metrics, alerts, and measured load tests. The 100-million-user goal is not proven by code or CI alone.
6. **Schedule encrypted off-site backups and run an isolated restore drill**; document recovery-point and recovery-time objectives. Existing scripts are not evidence that production backups are running.
7. **Verify deployment and release**: confirm Render health/release SHA, Vercel deployment, Android debug/release builds, signing keys and real-device journeys. GitHub CI does not itself deploy or prove live services are healthy.
8. **Finish business acceptance journeys** for inventory concurrency, order cancellation/refunds, delivery, support, school reconciliation and owner-facing subscription renewal/lock/grace-period behavior with test workspaces and test payments.

## Safety guarantees for this work

- No production database was accessed or modified by these repository edits.
- No production payment was initiated.
- No destructive database migration was run.
- New schema indexes are declared in the explicit index migration; operators must run it against the intended database under their normal change-control process.
- Mark each external acceptance item complete only after collecting the relevant live evidence.

## Verification update — 2026-10-22

After the commission-free callback and legacy POS regression fixes, GitHub Actions passed on source revision `9521e832cd88a3b5d5598fc6d5f4d0b50fd95041`:

- Backend: **190 tests passed, 0 failed**.
- Backend lint/syntax checks: passed.
- `npm audit --audit-level=high`: passed; 0 vulnerabilities reported.
- Backup/restore shell syntax and restore-safety regression checks: passed.
- Flutter analysis and Flutter tests: passed.
- Flutter web build: passed.
- Android debug APK build: passed.
- Full CI and quality-check workflows: both passed.

Evidence: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39733758117), [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39733758201), and [detailed verification record](VERIFICATION_2026-10-22.md).

These are automated checks, not a claim that production is deployed or every feature is accepted. Vercel reported a deployment rate limit for this revision; live Daraja payments, signed Android release, production migration/restore, full offline acceptance, full E2EE protocol requirements and 100-million-user load testing remain open. See the detailed verification record for the complete release gates.


## Latest verification update — 2026-10-22

The full CI and quality workflows have now both completed successfully for source revision
[`04286915efc84a3ec53f27c09c7e5a355032cd8f`](https://github.com/isaacokubi/chatify/commit/04286915efc84a3ec53f27c09c7e5a355032cd8f).

- Backend: **192 tests passed, 0 failed**.
- Dependency audit: **0 vulnerabilities reported** at the configured high-severity audit threshold.
- Backend lint/syntax and backup/restore safety checks: passed.
- Flutter analysis and Flutter tests: passed.
- Flutter Web build: passed.
- Android debug APK build: passed (not a signed production release).
- [Full CI workflow](https://github.com/isaacokubi/chatify/actions/runs/39736401352) and [quality workflow](https://github.com/isaacokubi/chatify/actions/runs/39736401343): both passed.

The test and build statements above apply to this tested source revision. This documentation-only follow-up will trigger CI again; its own result must be checked before claiming the newest documentation commit has passed. Passing CI does not certify live Vercel deployment, live Daraja settlement, full end-to-end encryption, complete offline behavior, production restore readiness, or 100-million-user scale. Keep those release gates open until independently tested.


## Daraja callback reconciliation follow-up

The follow-up branch `test/daraja-callback-reconciliation` extracts the callback state transition into `server/src/daraja-callback.js` so the route and automated tests use the same validation and idempotency boundary. Regression tests cover valid success, malformed request references, malformed result codes, amount/phone/receipt mismatches, failed/cancelled results, duplicate completed callbacks, and a callback that loses the atomic transition race. The new helper is included in the backend syntax/lint command.

These tests use controlled provider payloads and a fake persistence boundary. They do **not** prove that Safaricom credentials work, that a real STK prompt reaches a handset, or that the deployed Render service is running this branch. Live sandbox testing, deployment health/release confirmation, and a real database reconciliation remain separate release gates. Do not claim production payment acceptance is complete until those checks are actually run.
