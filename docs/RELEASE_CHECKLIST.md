# Production release checklist

## Current continuation status (2026-10-25)

This section supersedes older status rows below where they conflict. Evidence is local unless explicitly labeled otherwise.

| Area | Status | Evidence / action required |
|---|---|---|
| Daraja sandbox configuration | PARTIAL | Sandbox mode and key/secret, shortcode, passkey, and HTTPS callback URL are present. Callback token is missing; configured callback host failed DNS resolution. The user supplied a sandbox test phone, but no STK was sent. Add the callback token and correct publicly reachable isolated HTTPS URL, then verify DNS/route delivery before initiation. |
| Daraja sandbox OAuth | PASS (genuine, current run) | Token-redacted sandbox OAuth returned HTTP 200 and an access token was present. OAuth success does not verify STK, callback or settlement. |
| Durable uncertain STK recovery | PASS (local) | Attempt stored before provider request; stale interrupted attempts become review-required and remain pending; no automatic uncertain retry. Without `CheckoutRequestID`, status query is unavailable and admin/provider statement review is required. |
| Authorized manual review | PASS (local workflow) | Platform-admin-only self-STK review and school admin/staff tenant-scoped verification require transaction fields/evidence/reason, persist reviewer/time/source, use atomic state claims and avoid duplicate receipt application. Manual review is labeled separately from provider callback verification. Operational provider evidence remains required for a real payment. |
| Callback/reconciliation race safety | PASS (local simulation) | Disposable Mongo full suite passed 234/234, including callback auth/validation, retries, concurrency, reconciliation and exactly-once synthetic school balance/receipt assertions. No genuine provider callback. |
| Backend and mobile checks | PASS (local) | Lint exit 0; ordinary backend 233 pass/1 guarded skip; disposable Mongo backend 234/234; focused payment/school/POS 4 files pass; Flutter 35/35; analyzer exit 0 with 28 info diagnostics; web build exit 0 (217.1s); Android debug APK exit 0 (71.5s); audit 0 vulnerabilities. |
| Daraja genuine STK / callback / final balance | BLOCKED | No STK was attempted. The user approved a sandbox phone, but `MPESA_CALLBACK_TOKEN` is missing and the callback host did not resolve. Configure the tokenized route on a safe public isolated HTTPS endpoint, confirm DNS and POST callback delivery, then collect actual STK, callback, state, receipt and balance evidence. |
| Diff whitespace check | PASS | `git diff --check` exited 0 after source and documentation changes. |
| Production release | BLOCKED | Remaining Daraja external test, release signing, physical-device acceptance, production secrets/backup/monitoring and legal/privacy review remain open; do not release on local test evidence alone. |

Audit snapshot: 2026-10-25, branch `fix/flutter-fee-and-spark-tests-oct-2026`, HEAD `51e47a92080c542059bad345cfa00385daf171fe`. Local changes remain uncommitted. This is a readiness review, not release authorization.

| Area | Status | Evidence / action required |
|---|---|---|
| Payment state and callback correctness | PASS (local) | Backend tests and synthetic disposable-Mongo API integration passed. STK acceptance and ambiguous responses remain pending; callback auth, amount/reference checks, terminal handling, and duplicate/concurrent processing are covered locally. |
| Reconciliation and school balance/receipt | PASS (local) | Authenticated, bounded and claimed reconciliation; query evidence without a provider receipt remains pending. Synthetic school payment updates one receipt and balance once. No live settlement evidence. |
| Daraja OAuth | PASS (external, prior run) | Sandbox OAuth returned HTTP 200; no token retained or logged. Not repeated during this final continuation. |
| Daraja STK and provider-delivered callback | BLOCKED | The ignored local environment lacks the required callback tokenized URL and no approved test phone or isolated public callback receiver is configured. Configure those securely, validate the exact sandbox URL/host and isolated database, initiate one approved sandbox request, then retain redacted provider response/callback evidence. |
| Manual payment verification and unresolved payment recovery | BLOCKED / REVIEW | A payment with no checkout identifier cannot be verified by STK query. No platform manual-confirm endpoint exists; school staff reconciliation exists but ambiguous responses remain pending. Define an audited operational evidence procedure before production use; do not infer settlement from elapsed time. |
| Disposable database safety | PASS (local) | `CHATIFY_MONGO_TEST_URI=mongodb://127.0.0.1:27018/chatify npm test`: 233 passed, 0 failed, 0 skipped on a no-volume MongoDB 7 container bound to loopback. No Atlas writes during this continuation. |
| Backend unit suite and lint | PASS | `npm test`: 232 passed, 0 failed, 1 guarded skip. `npm run lint`: exit 0. `node --test src/payments.test.js src/school.test.js src/school-fees.test.js src/business-pos.test.js`: 4 file-level tests passed. |
| Flutter tests and analysis | PASS | Flutter tests 35/35, exit 0. Analyzer exit 0 with 28 informational diagnostics and no errors. |
| Flutter web build | PASS (local) | JavaScript build exit 0 in 230.7s. WASM dry-run has `dart:html`/`dart:js_util` and JS interop warnings; this is not WASM support evidence. |
| Android debug build | PASS (local) | `app-debug.apk` built, exit 0 in 76.9s. Gradle emitted native-access and `mobile_scanner` KGP warnings. This is not a signed release artifact. |
| Release signing and AAB | BLOCKED | No approved release signing configuration or AAB evidence. Configure signing outside source control and build/review a signed bundle. |
| Physical Android installation and acceptance | BLOCKED | No device/emulator acceptance evidence. Test install/upgrade, payment states, receipt view, media, offline/reconnect and duplicate submissions on supported devices. |
| Database backups and recovery | BLOCKED for production | Local synthetic backup/restore was previously verified. Production backup encryption, access controls, restore drill, RPO/RTO and rollback owner must be evidenced. |
| Production secrets and Daraja configuration | BLOCKED | Configure production-only credentials in approved secret management; use HTTPS callback domain, tokenized route and reverse-proxy log redaction. Confirm Safaricom production approval and never test with real money. |
| Email/SMTP delivery | BLOCKED | SMTP/Nodemailer mocks pass; `SMTP_URL` and `SMTP_FROM` unavailable. Configure authorized sender and approved test inbox, then verify delivery and duplicate/retry behavior. Resend is not implemented. |
| FCM delivery | BLOCKED | Mock tests pass; project ID/service credentials are unavailable. Configure approved project credentials and test a controlled device token. |
| Cloudinary upload | NOT TESTED live | Mock validation/provider tests pass. Credentials exist, but no dedicated test folder was configured; no upload was made. Configure a test folder and synthetic asset, then verify access/cleanup without touching production assets. |
| Auth, roles and tenant isolation | PASS (scoped) | Prior documented Atlas read-only demo checks and current synthetic API tests cover listed roles/endpoints. This does not establish every endpoint’s complete cross-tenant security. Copied JWT remains valid until expiry/session-version change; server-side logout revocation is unsupported. |
| Rate limiting, monitoring and incident response | NOT TESTED | Review deployed proxy/IP rate limits, alerting, redacted logs, incident contacts, rollback and payment reconciliation runbook. |
| Dependency audit | PASS | `npm audit --audit-level=high`: 0 vulnerabilities. |
| Privacy/regulatory review | BLOCKED | Responsible owner/adviser must document Kenya data-protection controller/processor role, child/guardian safeguards, registration/exemption, retention and applicable payments authorization. Source review is not legal approval. |
| Final source review and diff | PASS (local review only) | `git diff --check` exited 0; current branch, HEAD/upstream divergence, staged/unstaged changes and untracked files were reviewed. No files staged. Existing work remains uncommitted. This is not approval to push, merge, preview or deploy. |

Release decision: **NOT READY** until the Daraja external lifecycle, production configuration, signed release/device acceptance, and required operational/privacy gates have evidence and the final reviewed diff is approved.
