# Chatify Phone Test and Outstanding Release Checklist — 2026-11-14

## Purpose

This guide records the hands-on Android phone test sequence and every known release gate that remains after PR #101. Run the phone checks against the exact APK and API commit intended for the pilot. Record the date, device model, Android version, app version/commit, tester, expected result, actual result, and evidence for each check.

**Current decision: controlled testing only.** The automated checks listed in the onboarding readiness record passed, but that does not mean the app has passed physical-device, live payment, recovery, privacy or customer acceptance testing. Do not enable real-money collection or enter real school/student production data until the applicable gates below are signed off.

## 1. Prepare the Android phone

1. Use a supported Android phone with a working internet connection.
2. Enable Developer options: Settings → About phone → tap Build number seven times (wording varies by manufacturer).
3. Open Developer options and enable USB debugging.
4. Connect the phone to the computer with a data-capable USB cable and accept the phone's “Allow USB debugging” prompt.
5. Confirm the phone is detected with `adb devices`. Its state must be `device`, not `unauthorized`.
6. Install the fresh debug APK using the build/install commands in the repository README or the commands supplied with this guide.
7. Use a dedicated test account and test tenant. Do not use a real customer's data or a production payment method.

## 2. Android phone acceptance sequence

Mark each item PASS, FAIL or BLOCKED. A test is not PASS merely because a screen opens; verify the expected result and capture evidence.

### A. Install, launch and session

- [ ] Install the new APK over the existing test installation. Confirm installation completes without package/signature errors.
- [ ] Launch the app from the launcher. Confirm it reaches the sign-in screen without crashing or remaining on a blank screen.
- [ ] Sign in with a valid test account. Confirm the correct tenant/workspace and role are displayed.
- [ ] Force-close and relaunch. Confirm the session behaves as designed and does not expose another account's data.
- [ ] Sign out. Confirm protected screens/data are no longer accessible.
- [ ] Sign in again as a different test account. Confirm the previous account's cached data is not shown.

### B. Connectivity and user-friendly errors

- [ ] With Wi-Fi/mobile data enabled, sign in and load the main screens.
- [ ] Turn off both Wi-Fi and mobile data, then trigger a request that needs the server. The user-facing message should clearly say: **“Connect to the internet or Wi-Fi to continue.”**
- [ ] Confirm there is no raw exception, stack trace, HTML error page, technical URL, JSON payload or confusing blank state.
- [ ] Restore connectivity and retry. Confirm the screen recovers without reinstalling or clearing app data.
- [ ] Test a server/API timeout and a server-unavailable response where safely possible. Confirm the message is short, actionable and does not expose internals.
- [ ] Check empty lists (no customers, products, messages, learners, transactions, notifications, etc.). Show a concise empty-state message and a relevant action; do not show a connectivity error when the request succeeded and the list is genuinely empty.

### C. Navigation and role permissions

- [ ] Visit each module available to the test role. Confirm navigation, back actions, tabs, dialogs and forms work.
- [ ] Confirm unavailable modules/actions are hidden or clearly denied; they must not be enabled by changing client-side state.
- [ ] Test owner/admin, manager/staff and read-only viewer accounts separately.
- [ ] As a viewer, attempt create, edit, delete, export and settings changes. All prohibited writes must be denied by the server.
- [ ] Confirm account switching does not retain the prior user's workspace, permissions or cached records.

### D. Business workflow — Makena's Market pilot

Use synthetic products and customers until the business owner approves the controlled pilot.

- [ ] Provision the business owner; add manager and read-only viewer accounts.
- [ ] Create/edit products, categories, customers, branches and invoices.
- [ ] Verify quantities, prices, discounts, taxes (if configured), totals and stock movement.
- [ ] Complete a test POS sale and verify the resulting sale record, receipt and stock balance.
- [ ] Verify the viewer cannot create, edit, delete, export or change business settings.
- [ ] Submit a write, disable connectivity before the response, reconnect and retry. Confirm no duplicate sale, invoice, stock deduction or receipt is created.
- [ ] Attempt to access another business's records using a separate tenant account. Access must be denied and no records disclosed.
- [ ] Verify business payment configuration is tenant-specific. Do not collect real money during this test.

### E. School workflow — Lakeview Community School pilot

Use synthetic learner and guardian data until privacy/legal approvals and customer consent are complete.

- [ ] Provision school administrator, staff and parent/guardian test accounts.
- [ ] Create classes, fee structures, learner records and attendance entries.
- [ ] Link a parent only to their own test learner(s). Confirm they cannot view unrelated learners.
- [ ] Confirm staff permissions are limited to their assigned role/scope.
- [ ] Verify fee balances, invoice/statement calculations and receipts.
- [ ] Confirm only authorized school owners/admins can change school settings and payment credentials.
- [ ] Attempt cross-school access using a second test school account. It must be denied.
- [ ] Do not use real children's data until the privacy and guardian-notice gate is approved.

### F. Offline behaviour, retry and duplicate prevention

- [ ] While online, create or update a harmless test record and confirm it appears once.
- [ ] Go offline and exercise every workflow advertised as offline-capable. Confirm the UI indicates pending/saved state accurately.
- [ ] Reconnect and allow synchronization to finish. Confirm the record appears once on the originating device and on another authorized client.
- [ ] Rapidly tap submit twice and repeat a request after a simulated timeout. Confirm one logical operation, one sale/payment/receipt and no duplicate side effects.
- [ ] Force-close while a mutation is pending, relaunch and reconnect. Confirm the queue recovers safely and does not lose or duplicate work.
- [ ] Confirm failed operations are visible and retryable without creating duplicates.

### G. Media, notifications and communication

- [ ] Upload an approved small test image and video. Confirm upload, preview, ownership and access permissions.
- [ ] Test invalid file type and oversized file handling. The app should give a concise actionable message.
- [ ] Confirm one tenant cannot access another tenant's media by changing a URL or record identifier.
- [ ] Test push notification delivery to an approved test device and confirm tapping a notification opens the correct authorized screen.
- [ ] Test email/SMS only with controlled test recipients.
- [ ] If chat/calls are in the pilot scope, test send/receive, reconnect, permissions, call setup/teardown and notification behaviour on two authorized test accounts.

### H. Logout, revocation and session security

- [ ] Sign out while online. Confirm the server revokes the current session and protected API requests using that token are rejected.
- [ ] Sign out while offline. Confirm local credentials/session are cleared and local logout succeeds; after reconnect, confirm the old token cannot regain access.
- [ ] Reuse a previously revoked token in a controlled test. It must be rejected.
- [ ] Confirm Socket.IO disconnects/rejects the revoked session.
- [ ] Confirm logs and error messages do not expose access tokens, passwords, callback tokens or personal data.

## 3. Payment sandbox test — required before any payment pilot

Do not use real money. Obtain approved Daraja sandbox credentials, test phone, shortcode/merchant configuration and callback URL/token through the provider's secure channel. Never paste secrets into chat or commit them to Git.

- [ ] Verify sandbox mode and tenant-specific merchant configuration.
- [ ] Start a checkout and confirm the STK prompt reaches the approved test phone.
- [ ] Accept the prompt; verify callback delivery, provider status query, amount, phone and receipt/reference.
- [ ] Reject/cancel a prompt; verify the payment remains unpaid and workspace access is not unlocked.
- [ ] Leave a payment pending; reopen the app and confirm status polling resumes rather than starting a duplicate STK prompt.
- [ ] Simulate delayed and duplicate callbacks. Confirm exactly one payment/balance/receipt update.
- [ ] Test wrong callback token, amount mismatch, phone mismatch, provider timeout, malformed callback and lost STK response. All must fail safely and be auditable.
- [ ] Verify a failed, cancelled or pending payment never unlocks paid access.
- [ ] Verify merchant/customer funds are not routed through the Chatify platform shortcode; settlement must use the approved tenant merchant route.
- [ ] Reconcile the app's payment record with provider sandbox status and receipt.

**Gate:** No live collection until the merchant/provider approval, callback delivery, reconciliation and settlement route are verified and signed off.

## 4. Remaining non-phone release gates

### Hosting and production configuration
- [ ] Configure Render HTTP health-check path as `/api/health`.
- [ ] Verify `https://chatify-api-c1eh.onrender.com/api/health` returns HTTP 200 and reports database connectivity.
- [ ] Verify the deployed commit exactly matches the approved `main` commit.
- [ ] Verify `NODE_ENV=production`, HTTPS, CORS allow-list, database access restrictions, JWT configuration/expiry, session revocation, rate limits and upload ownership.
- [ ] Verify secrets are high entropy, unique and stored only in the hosting secret manager; rotate any previously exposed credentials.
- [ ] Verify callback tokens and secrets are redacted from application, proxy, analytics and error logs.
- [ ] Decide whether the Render free single-instance plan provides sufficient availability/capacity for paying tenants; configure an appropriate production plan and alerting.

### Dependency and application security
- [ ] Review and resolve or formally accept the six reported moderate transitive `glob`/`minimatch` advisories. Do not force major-version overrides without compatibility tests.
- [ ] Re-run backend install, audit, syntax/lint and full test suite after any dependency change.
- [ ] Extend tenant-isolation tests to exports, files/media, integrations, audit logs, payment reconciliation and administrative actions.
- [ ] Complete an independent security review/penetration test for sensitive tenant boundaries and administrative operations.

### Backup, recovery and operations
- [ ] Verify encrypted, off-site backups and tenant-scoped backup access.
- [ ] Restore a recent backup into a separate isolated database; verify record counts, integrity and application startup.
- [ ] Verify retention and deletion procedures.
- [ ] Configure monitoring and prove alert delivery to a named operator.
- [ ] Document incident response, escalation, rollback and service recovery procedures.

### Integrations
- [ ] Verify SMTP using a controlled inbox.
- [ ] Verify Firebase Cloud Messaging/push using an approved test device.
- [ ] Verify Cloudinary using synthetic media and confirm upload limits, transformations and tenant ownership.
- [ ] Keep any unverified integration disabled or clearly marked unavailable.

### Android production release
- [ ] Configure Android release signing in the secure build environment using `CHATIFY_ANDROID_KEYSTORE_PATH`, `CHATIFY_ANDROID_KEYSTORE_PASSWORD`, `CHATIFY_ANDROID_KEY_ALIAS` and `CHATIFY_ANDROID_KEY_PASSWORD`.
- [ ] Keep keystore files and passwords out of Git and chat.
- [ ] Build a signed release APK/AAB, verify its signature and install/update it on supported physical devices.
- [ ] Replace the sample Android application ID `com.example.chatify` with an organization-owned ID before public store distribution, with a planned migration strategy if existing installs must update.

### Privacy and legal
- [ ] Obtain Kenyan legal/privacy review for Data Protection Act obligations and ODPC registration or exemption as applicable.
- [ ] Document controller/processor roles, data processing terms, retention, deletion, access requests and breach handling.
- [ ] Approve school/guardian notices and consent flows and children's-data safeguards before real learner data is entered.
- [ ] Approve customer-facing terms, privacy notice and support/contact escalation.

### Customer acceptance
- [ ] Complete the Makena's Market test checklist with owner/manager/viewer sign-off.
- [ ] Complete the Lakeview Community School checklist with administrator/staff/parent sign-off.
- [ ] Run tests against the exact deployed commit and record device/browser/desktop coverage.
- [ ] Close or explicitly accept all severity-1 and severity-2 defects before activation.

## 5. Existing automated verification — already recorded

The onboarding readiness audit records the following successful checks for PR #101 / commit `bdd29a75a1f6d8449e4d050f093f7f9d165ca880`:
- Backend: 266 tests passed, 0 failed, 0 skipped; lint and syntax checks passed.
- Flutter analysis and tests passed.
- Flutter Web build passed.
- Android ARM64 **debug** APK build and artifact upload passed.
- Vercel check passed.
- Render reported the deployment as live on that commit.

These are CI/deployment results, not proof that a new APK has been installed and tested on this phone. The physical-device checks in section 2 remain to be completed. The Render HTTP health endpoint also remains unverified until section 4 is completed.

## 6. Test result record

For every test, record:

| Field | Record |
|---|---|
| Test date/time and timezone | |
| Tester | |
| App version / Git commit | |
| Phone model / Android version | |
| API deployment commit | |
| Test case / section | |
| Expected result | |
| Actual result | |
| Result (PASS / FAIL / BLOCKED) | |
| Evidence / defect reference | |
| Retest date and result | |

## Release rule

Do not onboard paying tenants, enable live payment collection or enter real learner/student production data until the relevant phone, payment, hosting, security, backup, privacy and customer-acceptance gates have passed and are signed off. A debug APK is for controlled testing only, not production distribution.
