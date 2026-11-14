# First-Customer Onboarding Readiness — 2026-11-14

## Release decision

**Not approved for real customer production onboarding yet.** The application has working onboarding, school/business tenant modules, billing state machines and automated acceptance coverage. The changes in PR #101 improve zero-fee setup checkout and expand negative tenant-isolation tests. They do not replace live provider, hosting, privacy, recovery or real-customer acceptance.

## Source changes in PR #101

- School and business workspace checkout now runs before collecting a payer phone number. A zero-priced setup checkout completes without displaying an M-Pesa phone prompt or initiating a charge.
- When checkout returns a payment that already has an initiation timestamp, the client resumes status checking rather than starting a second STK prompt.
- The client refreshes workspace access only after the server reports the checkout as paid or the payment status as SUCCESS. A pending, failed or cancelled payment is not treated as paid.
- The disposable MongoDB API acceptance test now exercises two business organizations and two schools: cross-tenant reads are denied, customer lists remain tenant-scoped, and a viewer cannot create business records.

## Automated verification

PR #101 runs the repository's existing workflows:
- Backend dependency audit, Node tests, syntax checks and disposable MongoDB acceptance.
- Flutter analysis and widget tests.
- Flutter Web build and Android debug build.
- The first run exposed a test-fixture issue: the test tried to add an extra member beyond the tenant's configured seat limit. The fixture now reuses the existing manager seat for the viewer-permission assertion. The corrected backend quality run passed; the remaining workflow jobs must also finish successfully before merge.

Do not report the automated suite as passed until all final PR checks show success.

## Source-level authorization review

A source scan of the business and school API modules found tenant membership/role checks on the organization- and school-scoped route families. Business records are queried with the owning organization ID; school routes resolve an active school membership and role before access. PR #101 adds negative database-backed cases for cross-tenant access.

This is targeted verification, not a complete independent penetration test. Before launch, extend automated coverage to all sensitive modules, including exports, files/media, integrations, audit logs, payment reconciliation and administrative actions.

## Payment safety

- Do not enable live collection until the actual provider account, shortcode, callback URL/token and reconciliation path have been verified for the specific legal merchant/school.
- Test the full sandbox sequence: create checkout, send STK, accept or reject on the handset, receive the callback, query status, verify amount/phone/receipt, and confirm exactly one balance/receipt update.
- Exercise duplicate and delayed callbacks, callback amount mismatch, wrong token, provider timeout and lost STK response.
- Merchant invoice/order checkout must remain blocked unless a tenant-specific merchant settlement route is configured and approved. Do not route merchant funds through the Chatify platform shortcode.
- The repository's prior security review records Daraja OAuth sandbox verification, but live STK/callback delivery and real settlement remain unverified. No real payment was initiated as part of PR #101.

## Hosting and production configuration

Current Render service observed:
- Service: `chatify-api`
- Repository/branch: `isaacokubi/chatify` / `main`
- Auto-deploy: enabled on commit
- Current live deploy at audit time: `53f7f2aadc2b301b95d0171fdbf8aa40a35d09e3`
- Latest merged application commit before PR #101: `26b7dfc60172a664d944fb75a0e6b3864d7cf251`

The live Render deployment therefore predates the merged mobile UX change and the PR #101 work. Merge and verify the new main-branch deploy before testing the final client build. Do not manually deploy a stale SHA.

The service currently has no configured HTTP health-check path. The API exposes `/health` and `/ready`; configure Render's HTTP health check to use `/health`, then verify the endpoint returns 200 with the database connected. The current Render service integration available to this audit did not expose environment-variable values, so `NODE_ENV`, JWT secrets, database credentials, Daraja mode/tokens and other production settings were not verified or changed.

The last observed Render application error-log query returned no error-level entries in its queried seven-day window. HTTP request and latency metrics were empty, so this is not proof of healthy user traffic. The service is on the free single-instance plan. A production capacity/availability decision is required before onboarding paying tenants.

The Render build log reported six moderate dependency advisories. The GitHub high-severity dependency audit passed; the moderate findings still need review and a documented disposition.

## Security, privacy and operations gates

Before storing real school or business data:
1. Rotate any previously exposed provider credentials and callback tokens; use unique, high-entropy production secrets in the hosting secret manager.
2. Verify production mode, HTTPS, CORS allow-list, database access controls, JWT expiry/session invalidation, rate limits, upload ownership and secret/log redaction.
3. Confirm callback tokens in URL paths are redacted from hosting, proxy, analytics and error-reporting logs.
4. Verify tenant-scoped backup access, encrypted off-site backups, retention, and a successful restore into a separate isolated database.
5. Prove monitoring and alert delivery to an assigned operator; document escalation, incident response and rollback.
6. Complete Kenyan privacy/legal review for controller/processor roles, ODPC registration or exemption as applicable, school/guardian notices and consent, children's data safeguards, retention, deletion and breach handling.
7. Verify SMTP, FCM/push and Cloudinary with approved test credentials, a controlled inbox/device and synthetic uploads. Keep unavailable integrations disabled.
8. Configure release signing credentials and verify a signed production build. A debug APK is not a production release.

## Controlled pilot acceptance

Use separate real tenant records and separate administrator accounts. Do not reuse the demo credentials or seed records.

### Makena's Market — business pilot
- Provision the owner; add a manager and read-only viewer.
- Confirm the viewer cannot create, edit, delete, export or change settings.
- Create products, customers, branches and invoices; verify totals and stock.
- Test POS, receipts and tenant-specific merchant payment settings.
- Test duplicate submissions, offline mutations, retries and reconnect without duplicate sales.
- Verify another business account cannot read any Makena's Market records.

### Lakeview Community School — school pilot
- Provision the school administrator, staff and parent/guardian accounts.
- Link parents only to their own learners; verify staff and parents cannot read unrelated learner records.
- Create classes, fee structures, attendance and academic records.
- Verify fees, provider callback/query reconciliation, balances and receipts.
- Verify only the school owner can change school settings and payment credentials.
- Verify another school account cannot read any Lakeview records.

For each pilot, retain a dated checklist, synthetic or consented test records, expected/actual results, issue list and customer sign-off. Run the full test on the exact deployed commit and supported phone/browser/desktop clients.

## Go-live rule

Open onboarding only after:
- PR #101 is merged with all required CI checks green.
- The Render service is running the exact merged main commit and passes HTTP health checks.
- Production configuration and secret rotation are verified by the operator.
- Sandbox payment/callback/reconciliation tests pass for each supported tenant payment flow; production provider approval is documented.
- Security, privacy, backup/restore and alert-delivery gates are signed off.
- Both controlled customer pilots pass and the customers approve activation.

Until then, keep real-money collection and real school/student production data disabled.
