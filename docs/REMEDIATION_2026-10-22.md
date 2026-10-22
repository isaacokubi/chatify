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
- Chat message creation accepts a validated client mutation ID. A unique partial index prevents duplicate messages when a client retries after an ambiguous network timeout; a reused ID cannot be applied to a different conversation.
- The Flutter app now stores encrypted outgoing message envelopes in an account-scoped Flutter Secure Storage outbox (up to 50 queued messages per conversation), displays the queued message locally, and retries after the chat socket reconnects. Queue writes fail closed if secure storage is unavailable; no plaintext preferences fallback is used.
- The outbox is at-least-once delivery with server-side deduplication. Multi-device outbox synchronization, explicit per-message retry/delete controls, and broader conflict/recovery tests remain release gates.

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

### Existing CI and reliability work
- API health readiness reports database disconnection as HTTP 503.
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
