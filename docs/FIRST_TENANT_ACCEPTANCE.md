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
