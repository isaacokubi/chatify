# First School and Business Onboarding Acceptance

**Audit date:** 2026-11-11  
**Repository:** `isaacokubi/chatify`  
**Reference platform:** Global Tours first-tenant acceptance and production release discipline  
**Target:** one real school workspace and one real business workspace

## 1. Purpose and evidence rules

This runbook adapts the tenant onboarding controls used by Global Tours to Chatify's actual domain model. Chatify is not a tour-booking application: its school workspace, business organization, messaging, memory, storefront, subscriptions and payment flows have separate domain rules. Do not copy Global Tours models, tenant middleware or payment assumptions into Chatify.

A feature is not accepted merely because a screen, route, model, seed fixture or green build exists. Record the exact commit, command, result and external evidence. Use these statuses:

- **PASS** — the stated acceptance scenario was executed and passed.
- **PARTIAL** — implementation/tests exist, but some role, isolation or end-to-end behavior is unverified.
- **BLOCKED** — an external credential, provider approval, infrastructure or owner action is required.
- **NOT RUN** — no current execution evidence is available.
- **NOT IMPLEMENTED** — the required behavior is absent.

Never turn a mock, dry run, unit test, old CI result or demo fixture into a live acceptance claim.

## 2. Current repository baseline

The repository already contains implementation and documentation for school workspaces, business organizations, demo seeding, platform administration, M-Pesa, security, backup/recovery and acceptance testing.

The main branch history includes:
- `1f122ded97fdcb1ee172d847f21c7ed0c163d1ad` — prepared one school and one business demo tenant, documented the two-tenant seed and dry-run counts.
- `a2096f6a54dd5c29ae4fe0371a1bfc3660178fd4` — corrected school seed messaging to use the current school message/conference records.
- `200e26f39c4677917fe97afd7a7fc2411e357b33` — latest main commit observed during this audit (2026-11-07).

The existing demo dataset defines:
- **Lakeview Community School:** Grace (school administrator/workspace owner), Peter (staff), Miriam (parent/guardian), six linked student records and seeded school activity.
- **Makena's Market:** Nia (business owner), Sam (manager), two branches, catalogue, customers and example business documents.
- **Platform:** one administrator and two general chat demo accounts.

The seed is a non-production demonstration fixture. It is not proof that a real school or business has been onboarded, that production tenant isolation has passed, or that provider services work.

## 3. Required onboarding architecture

### Platform administrator

- Provision the initial platform administrator only through the documented server-side `npm run seed:admin` flow.
- Set `MONGODB_URI`, `ADMIN_NAME`, `ADMIN_EMAIL` and a unique `ADMIN_PASSWORD` privately.
- The password must meet the seeder's 12–72 UTF-8 byte rule.
- Never add an administrator password, database URI, JWT secret, encryption key or provider credential to Git, mobile source, documentation or logs.
- Verify that non-admin accounts receive HTTP 403 from every platform-admin route. Hiding an Admin tab in Flutter is not authorization.

### First real school

Use the authenticated school-administration onboarding path already implemented by Chatify; do not use the demo seeder or create a school by editing MongoDB documents manually.

Before inviting real users, verify:
1. A school is created with its own stable identifier, name, contact details, timezone/currency configuration where supported, and an initial school administrator.
2. The administrator can manage school membership and only the school-owned records.
3. Staff access is limited to their permitted school functions.
4. A parent/guardian can access only the linked child/student records and permitted messages, attendance, assessments, fee balances and receipts.
5. A user from another school cannot read, change, list, export or infer this school's students, attendance, assessments, conferences, messages, fees, payment details or documents by changing an identifier.
6. School fee payment remains pending until provider evidence is matched and verified. A manual reference, screenshot, accepted STK request or client-supplied paid flag is not settlement proof.
7. The school can operate with payments unconfigured; no global/platform shortcode or credentials may silently receive school money.

Do not enter real children's data until the school has approved its privacy notice, guardian consent process, retention rules, access policy and incident contact.

### First real business

Use the authenticated business-organization onboarding path already implemented by Chatify; do not use the demo seeder or manually create organization documents.

Before inviting customers or staff, verify:
1. The business organization has a unique stable identity/slug and a verified owner.
2. The owner can invite or manage members and assign only supported organization roles.
3. Manager, sales, finance, support, fulfilment and viewer permissions are checked by the API, not only by Flutter visibility.
4. A member of another business cannot read or mutate this organization's customers, catalogue, branches, quotes, orders, invoices, tasks, suppliers, cases, POS settings, payment credentials or reports.
5. Public storefront/search endpoints expose only explicitly public fields and only when publication is enabled.
6. Prices and totals are calculated server-side; the client cannot submit a trusted price or paid status.
7. Business invoice/order settlement is blocked until merchant-scoped provider settlement is implemented and accepted. Do not route a merchant sale through Chatify's platform shortcode.
8. Business payment credentials are encrypted, tenant-specific and never serialized to ordinary member/public responses.

## 4. Tenant-isolation acceptance matrix

Run these scenarios against an isolated disposable MongoDB database, not production. Use at least two school workspaces and two business organizations for negative tests, even though the first customer rollout will start with one of each. One tenant alone cannot prove cross-tenant denial.

| Scenario | Required result | Evidence |
|---|---|---|
| School admin reads own school | Allowed | API response and test |
| School staff reads permitted own-school records | Allowed | API response and test |
| Parent reads linked student only | Allowed | API response and test |
| Parent requests unrelated student ID | 403/404; no data leakage | API response and test |
| School A user requests School B record | 403/404; no data leakage | API response and test |
| School A user attempts School B write/export | Rejected | API response and test |
| Business owner reads own organization | Allowed | API response and test |
| Business manager uses permitted functions | Allowed | API response and test |
| Viewer attempts write/finance/admin action | Rejected | API response and test |
| Business A user requests Business B customer/order/catalogue | 403/404; no data leakage | API response and test |
| Public storefront for unpublished business | Not discoverable / rejected | API response and test |
| Non-platform-admin calls admin endpoint | HTTP 403 | API response and test |
| Revoked member continues using old token | Access denied according to current session/membership checks | API response and test |

Do not call this matrix passed based only on the existing unit tests. Execute it against MongoDB with real route handlers and representative records.

## 5. Demo seed: safe use

The current demo seed is guarded and must remain separate from production onboarding.

From `server/`, after setting private environment variables for a dedicated disposable development database:

```sh
npm run seed -- --dry-run
npm run seed
```

Required environment:
- `NODE_ENV=development`
- `CHATIFY_SEED_DEMO=YES`
- `MONGODB_URI` explicitly naming a disposable database
- `SEED_DEMO_PASSWORD` (12–72 UTF-8 bytes)

The seed refuses non-development mode, missing explicit confirmation and production-named databases. A database name without a demo/dev/test marker requires a separate explicit acknowledgement. It does not drop collections and only reconciles records carrying its own seed marker. Inspect the dry-run summary and verify the connected database before running the write operation.

The read-only demo-account HTTP smoke test is separate:

```sh
CHATIFY_API_URL=https://<approved-api-host> \
CHATIFY_DEMO_PASSWORD='<inject privately; do not place in shell history>' \
node scripts/demo-account-smoke.mjs
```

Use a protected environment/secret manager to inject the password. This script authenticates eight demo accounts and performs read-only API checks (login updates last-seen metadata); it does not test browser UI, WebSockets, data mutation, real school/business creation, or payment-provider acceptance. Never point the demo seed at production.

## 6. Payment, email, media and notification gates

### M-Pesa / Daraja

- Keep mock mode clearly labelled as local simulation.
- Verify each school uses its own authorized Daraja credentials and callback configuration.
- Verify each merchant POS uses that merchant's own authorized app credentials and shortcode.
- Confirm callback/query agreement, exact amount/phone/reference/provider context, duplicate/replay protection and exactly-once ledger/receipt effects.
- Do not treat STK initiation as payment success.
- Do not enable real business invoice/order checkout while merchant-scoped settlement is explicitly blocked.
- Resolve the documented Dynamic QR sandbox entitlement/HTTP 401 blocker before advertising that flow.
- Rotate any previously exposed Daraja keys, passkeys and callback tokens through authorized provider/hosting controls. Do not paste replacement secrets into chat or Git.

### Other external services

- SMTP: verify an approved sender, password-reset delivery, retries and duplicate behavior.
- Firebase/FCM: verify a real test device receives the expected notification.
- Cloudinary: upload and retrieve a synthetic test asset in a dedicated test folder, then verify cleanup and access controls.
- Stripe/PayPal: verify account eligibility, webhook signature handling, idempotency, refunds and reconciliation before enabling live mode.
- Backups: perform an encrypted off-site backup and restore into a separate isolated database; verify record counts and checksums.
- Monitoring: prove alert delivery to an owner-operated channel and document escalation/rollback contacts.

## 7. Privacy, child safety and legal review

Before onboarding the school, the school and platform owners must approve:
- controller/processor roles and written processing terms;
- privacy notice, lawful basis and parent/guardian consent;
- minimum collection of student information;
- role-based access and staff offboarding;
- retention/deletion rules consistent with legal and school-record obligations;
- breach notification and incident response contacts;
- data-subject request handling and export/deletion workflow;
- hosting region, subprocessors, backup retention and cross-border transfer review.

Do not claim ODPC compliance or legal certification based solely on application features. Obtain qualified local review for the intended deployment and school data-processing arrangement.

## 8. Go-live checklist

- [ ] Current main commit and branch recorded.
- [ ] Backend full tests and lint pass on the exact release commit.
- [ ] Flutter analysis, tests, web build and Android build pass on the exact release commit.
- [ ] Dependency/security audit passes; findings are triaged.
- [ ] MongoDB version, replica-set/transaction support, indexes and connection limits are verified.
- [ ] School and business cross-tenant tests pass on an isolated database.
- [ ] Admin and all school/business roles are tested through API authorization.
- [ ] First school and business records are created through the supported onboarding flow.
- [ ] Real customer records are not mixed with demo accounts or demo fixtures.
- [ ] Payment provider acceptance is completed per tenant or payment features remain disabled.
- [ ] SMTP, media and FCM behavior is verified or clearly disabled.
- [ ] Encrypted off-site backup and isolated restore drill pass.
- [ ] Monitoring, alerting, incident response and rollback are operational.
- [ ] Privacy/child-safety and contractual reviews are approved.
- [ ] Production deployment uses HTTPS, exact allowed origins and rotated secrets.
- [ ] Production runtime flags are explicitly set; no development fallback or demo mode is enabled.
- [ ] Browser and physical-device acceptance is recorded.
- [ ] Release owner signs off the evidence bundle.

## 9. Current acceptance status on 2026-11-11

This document is a release gate, not a certificate. The repository inspection found substantial existing code and tests, but the available repository evidence does not establish a fresh, end-to-end first-real-school plus first-real-business production acceptance.

| Area | Status | Reason |
|---|---|---|
| School/business demo fixtures | IMPLEMENTED | One school and one business are included in the guarded development seed. |
| Platform administrator seeding | IMPLEMENTED | Explicit environment credentials; no hard-coded default password. |
| Backend and mobile historical CI | HISTORICAL PASS | CI runs on the 2026-10-28 acceptance commit; latest main commit is newer. |
| Latest main CI | NOT VERIFIED | No GitHub Actions run was returned for the latest documentation commit; only a successful Vercel status was visible. |
| Demo-account hosted smoke | NOT VERIFIED | The audit report documents the script, but no current execution output was available. |
| School/business cross-tenant live acceptance | NOT VERIFIED | Requires isolated database-backed tests and real role-based API checks. |
| Live M-Pesa | BLOCKED / NOT VERIFIED | External tenant credentials/callback acceptance remain outstanding; business invoice/order settlement is intentionally guarded. |
| SMTP, FCM, Cloudinary | NOT VERIFIED | Provider delivery/upload acceptance requires owner credentials and test endpoints/devices. |
| Backup/restore and monitoring | NOT VERIFIED | Scripts and tests are not proof of a completed production restore/alert drill. |
| Privacy and child-safety approval | OWNER ACTION REQUIRED | Requires school/platform legal and operational approval. |

**Release decision: NOT YET APPROVED for real school/business production onboarding.** A controlled, non-production pilot may proceed only after the disposable environment, tenant isolation, role permissions, data privacy and provider boundaries above are verified. Keep real payment and sensitive student-data workflows disabled until their individual gates pass.


## 10. Owner dashboard entry points — implementation branch

The implementation branch adds dedicated Flutter owner overview screens:
- [School Owner Dashboard](SCHOOL_OWNER_DASHBOARD.md)
- [Business Owner Dashboard](BUSINESS_OWNER_DASHBOARD.md)

The School tab now opens the school-owner overview. It filters to the authenticated user's own school where the API reports `isOwner: true` and `role: admin`, then reads server totals for students, attendance, memberships and fee-balance records. Staff/parent users are directed to the existing role-aware School Workspace.

The Business tab now opens the business-owner overview. It filters the authenticated user's own organizations by the server-returned `ownerId`, then reads the organization-scoped dashboard metrics. Non-owner members are directed to the existing BusinessHub.

Both overview pages link to the existing full management workspace. They do not replace backend authorization. The client-side owner filters are for presentation only; server-side membership, role and organization checks remain mandatory.

Widget tests for school owner metrics, school staff exclusion and business owner organization filtering have passed in GitHub Actions on source commit `e1a0d623035ce138d0374ee970f2b260f4663329`. The full Flutter suite reports 38 passed and the analyzer reports no issues.

## 11. Updated release status

| Area | Status | Evidence / boundary |
|---|---|---|
| Dedicated school owner overview | IMPLEMENTED — CI PENDING | New `SchoolOwnerDashboard` widget and school-tab routing on the implementation branch. |
| Dedicated business owner overview | IMPLEMENTED — CI PENDING | New `BusinessOwnerDashboard` widget and business-tab routing on the implementation branch. |
| Owner dashboard widget tests | PASS | Eight new widget scenarios passed; full Flutter test suite reports 43 passed. |
| Existing school/business management workflows | EXISTING IMPLEMENTATION | Full SchoolWorkspacePage and BusinessHub retained and linked from the overview pages. |
| Backend tenant authorization | EXISTING IMPLEMENTATION; FRESH ACCEPTANCE NOT VERIFIED | Source inspection confirms school membership and business organization authorization paths; database-backed cross-tenant tests still required. |
| First real school and business | NOT VERIFIED | No live tenant was created or modified as part of this code change. |
| Production onboarding | NOT APPROVED | Payment, privacy, external provider, monitoring and restore gates remain separate release requirements. |


## 12. Latest CI and Android build evidence

On source commit `e993cd61e6d838abfba9167b767b53a13cbe137c`, GitHub Actions passed the backend suite, Flutter analysis, all 43 Flutter tests, Flutter Web build and Android debug build. The separate Android workflow uploaded an ARM64 debug/test APK. The signed release APK steps were skipped because release signing secrets are not configured. See [TEST_RESULTS.md](TEST_RESULTS.md) for workflow IDs, artifact digest and remaining acceptance limits.

This evidence does not complete the live two-school/two-business database isolation test, real first-tenant onboarding, production M-Pesa acceptance, child-data privacy approval, physical-device test or production restore/monitoring drills.

## 13. Authoritative implementation-branch update — 2026-11-11

This section supersedes older status rows above that say the latest CI is pending or describe this work as documentation-only.

- Application source tested: `e993cd61e6d838abfba9167b767b53a13cbe137c`.
- Documentation-only follow-up commits keep the acceptance records synchronized; see the open PR for the current review head.
- GitHub Actions full CI run `43002990331`: backend **259 passed, 0 failed, 1 guarded skip**; npm high/critical audit threshold passed; Flutter analyzer reported no issues; Flutter **43 tests passed**; Flutter Web and Android debug builds passed.
- GitHub Actions quality workflow `43002990086`: PASS.
- Android workflow `43002990318`: PASS. Debug artifact only; signed release packaging remains blocked on release signing credentials.
- The implementation is in the open draft PR, not merged to `main` and not deployed by this change.

### Owner dashboard and billing acceptance

The School tab now routes to a dedicated School Owner Dashboard. It filters to server-reported `isOwner: true` and `role: admin` school memberships, then requests server totals for students, attendance, memberships and fee-balance records. It checks `GET /api/workspace-billing/school/:schoolId` before fetching those protected metrics. A locked workspace shows the billing-required state and links to the existing school workspace/billing controls; it does not expose protected metric cards.

The Business tab now routes to a dedicated Business Owner Dashboard. It filters organizations to the authenticated owner ID, checks `GET /api/workspace-billing/business/:orgId`, and only requests organization dashboard metrics when billing is not locked. A pending platform approval is shown without offering checkout. Once approved, the owner can start the existing Chatify setup/monthly subscription checkout. The client polls the existing payment status and refreshes access only after provider-reported success; checkout initiation alone does not unlock operations.

Eight widget tests cover school owner metrics, staff exclusion, business owner filtering, multi-workspace switching, school billing lock, business approval gating and zero-priced setup checkout. The tests are automated UI tests, not a live M-Pesa payment.

### Remaining release gates

Database-backed two-school/two-business cross-tenant integration, actual first-school and first-business onboarding, live M-Pesa and merchant settlement, real SMTP/FCM/Cloudinary delivery, production restore, monitoring/alert delivery, privacy/child-safety approval, signed release packaging and physical-device acceptance remain unverified or require owner action. Production onboarding remains **NOT APPROVED** until the relevant gates in the readiness report are evidenced.
