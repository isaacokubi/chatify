# First Business and School Onboarding Acceptance

**Purpose:** evidence the first real Chatify business workspace and first real school workspace independently, without treating demo fixtures, mocked payments, or a successful build as production acceptance.

**Reference standard:** this runbook adapts the evidence discipline used by Global Tours: isolated database-backed acceptance, fail-closed configuration, tenant/role isolation, repeatable seeded fixtures, explicit CI gates, backup/restore evidence, and a dated release decision. Travel-only modules are intentionally excluded.

## Current source-level onboarding paths

### First business

1. The business owner must have an active Chatify user account and authenticate.
2. Create the workspace with `POST /api/business/organizations`. The API assigns the authenticated user as owner; it does not accept a caller-supplied owner as authority.
3. A new business starts with `approvalStatus=PENDING` and billing `SETUP_PAYMENT_REQUIRED`. It is not yet a public, approved storefront.
4. A Chatify platform administrator reviews it through `GET /api/admin/business-approvals` and `POST /api/admin/business-approvals/:businessId/review`, choosing APPROVE or REJECT with a review note.
5. The owner completes the applicable workspace setup/billing flow. A business approval is not proof that a setup fee or subscription payment settled.
6. The owner configures the profile, branches, team, catalogue, customers and operational contacts. Invite staff only after their Chatify accounts exist.
7. Configure the business's own POS Daraja app credentials, shortcode, passkey and callback settings only when the merchant has the required Safaricom authorization. Credentials must be encrypted at rest and never returned in API responses.
8. Run owner/manager and unrelated-user authorization checks. Verify public storefront discovery exposes only approved, published businesses and public fields.

**Important payment boundary:** current source documentation records business invoice/storefront settlement as blocked where a merchant-scoped settlement flow is required. Do not accept real online invoice/storefront payments through the platform shortcode or describe manual payment matching as provider verification. Merchant POS STK/C2B each require their own sandbox acceptance.

### First school

1. The school representative must have an active Chatify user account and authenticate.
2. Submit `POST /api/schools/verification-requests` with the legal school name, proposed unique school code, county, official email and official phone.
3. A request returns HTTP 202 and remains pending; it does not create a school workspace.
4. An authorized Chatify school-verification reviewer approves/rejects through `POST /api/schools/verification-requests/:requestId/review`. On approval, the API creates the school and grants the requester the administrator membership.
5. Direct `POST /api/schools` is intentionally disabled (HTTP 403). Do not bypass the verification workflow for a real school.
6. The school administrator adds existing Chatify accounts as staff or parents, or issues the appropriate staff/parent join code. School administrators cannot be self-assigned by joining.
7. Register students as school records (not Chatify login accounts), link students to the correct parent/staff membership, and verify class/grade, attendance, assessment and fee visibility.
8. Configure the school's own payment profile. School-specific Daraja credentials are encrypted at rest; use a separate school callback token and a public HTTPS callback URL.
9. Verify parent, staff and administrator access separately. Parents must not see other families' records or staff-only information.

**Important payment boundary:** a pending STK request is not a paid fee. Confirm only after the stored checkout/merchant IDs, amount, payer, provider callback/query evidence and unique receipt are validated. Duplicate callbacks must not duplicate a receipt or fee-balance update. Manual review must remain labelled as manual review, not provider callback confirmation.

## Demo seed versus real onboarding

The repeatable `npm run seed` fixture intentionally creates one demo business (Makena's Market) and one demo school (Lakeview Community School), plus the eight demo accounts. It is development-only and must be run only against a dedicated disposable database with explicit confirmation and a test password.

The seed inserts records directly so that a demo can be explored. It does **not** prove the real business approval path, school verification-review path, workspace setup payment, live payment provider, production email, or deployed UI. Never use the demo seeder to create or approve a real customer's workspace. Do not copy demo users, students, contacts, phone numbers or fixture payments into a real tenant database.

The seed script performs record relationship checks and bcrypt verification. CI must additionally run it against a disposable MongoDB database and perform authenticated HTTP smoke checks for the seeded accounts. The test database must be isolated from Atlas/production and must be safe to drop.

The database-backed onboarding test also asserts that approval/verification alone does not unlock workspace operations: business and school APIs return the setup-billing-required response first. To continue testing member/student authorization in the same isolated fixture, the test explicitly disables the billing-enforcement flag on those disposable test records only. This is not payment acceptance and must never be copied to a real workspace; provider-confirmed billing remains a separate gate.

## Automated acceptance gates

| Gate | Required evidence | Pass condition |
|---|---|---|
| Seed safety | Unit tests for environment, explicit confirmation, database-name and password guards | Production/test misuse is rejected; dry-run performs no connection/write |
| Disposable MongoDB integration | `server/src/database.integration.test.js` against a dedicated loopback MongoDB test database | Test completes with zero skips/failures and drops only its exact disposable database |
| Demo tenant seed | `npm run seed -- --dry-run`, then `npm run seed` against a dedicated CI-only database | Exactly 1 business and 1 school planned; all seed relationship checks pass |
| Account authentication | Seed login verification and `server/scripts/demo-account-smoke.mjs` against local CI API | All eight identities/roles log in and read the expected API resources |
| Business isolation | Owner and manager can read the seeded business; unrelated accounts see no business membership | Organization reads are owner/member scoped; admin privileges remain platform-only |
| School isolation | School admin, staff and parent see only their school membership; unrelated accounts see none | School records and linked student data remain membership/guardian scoped |
| Business approval | Real API test of pending -> approved/rejected, reviewer identity and storefront visibility | Only platform admin can review; public listing excludes pending/rejected workspaces |
| School verification | Real API test of pending request -> approved/rejected and workspace creation | Only authorized reviewer can approve; one approval creates one school and admin membership |
| Billing | Setup/subscription state transitions and provider-confirmed idempotency | No workspace is marked paid from request initiation, screenshots or client input |
| Payment provider | Separate business POS and school Daraja sandbox lifecycle | Real sandbox prompt, HTTPS callback, provider query, receipt, correct tenant balance and duplicate replay evidence |
| Mobile/web | Flutter tests, web build, signed Android release and device/browser smoke | Relevant owner/admin/staff/parent journeys pass on supported clients |
| Operations | Current deployed SHA, health/readiness, monitoring, encrypted backup and isolated restore drill | Current release is identified and recovery evidence is retained |
| Privacy | Controller/processor assessment, school/guardian notices, consent, retention and access procedures | Responsible owner/legal adviser signs off before live student data is imported |

A test that is skipped, mocked, dry-run only, or not run against the current commit is not a PASS.

## Required negative tests

- A non-admin cannot review a business approval or school verification request.
- A business owner cannot change ownership by submitting another user's ID.
- A business manager cannot read or mutate an unrelated organization's customers, documents, POS charges or settings.
- An unapproved or unpublished business is not discoverable through public storefront APIs.
- A school request alone does not create a workspace; direct school creation remains rejected.
- A parent cannot promote themselves to staff/admin or read another family's student/fee records.
- A staff member cannot read records outside their assigned school/student scope.
- Wrong school/business callback token, shortcode, provider IDs, amount, payer or receipt must not settle a payment.
- Duplicate callbacks and concurrent retries must apply a receipt/balance/ledger effect exactly once.
- A platform payment must never settle a merchant invoice/order belonging to a business.

## Production environment and secrets

- Use a separate production Atlas database and separate disposable integration database.
- Keep `MONGODB_URI`, `JWT_SECRET`, school and POS encryption keys, Daraja credentials, callback tokens, SMTP and FCM credentials in the deployment secret manager.
- Rotate any previously exposed Daraja credentials/tokens before enabling provider flows. Coordinate rotation with pending transactions and proxy/access-log redaction.
- Require HTTPS and exact production CORS origins. Keep mock payment mode for local development only.
- Keep school and merchant callback tokens separate and at least 32 random characters. A tokenized callback URL is not a Safaricom cryptographic signature.
- Keep business POS credentials merchant-owned and school Daraja credentials school-owned. Never fall back to platform shortcode credentials.
- Do not claim KRA/eTIMS certification, CBK authorization, ODPC compliance, or Safaricom production approval from source code or unit tests.

## Current audit findings and decision

Reviewed against Chatify `main` on 2026-11-11:

- Existing demo fixture has one business and one school with role-linked demo accounts and record-level relationship checks.
- Real business creation is pending approval and workspace setup billing; platform admin review route exists.
- Real school creation requires a verification request and authorized reviewer approval; direct creation is disabled by design.
- The normal CI workflow previously ran `npm test` without a MongoDB service, so the destructive database integration test was skipped unless an operator supplied the guarded test URI.
- Historical test/readiness documents contain dated counts and mixed snapshots. Only CI results tied to the exact current commit should be treated as current evidence.
- Business invoice/storefront settlement and several live provider paths remain explicitly blocked or unverified in the existing acceptance documents.
- Production deployment, live provider delivery, signed mobile release, production backup/restore, and Kenya privacy/legal review are not proven by repository source.

**Decision: NOT CERTIFIED FOR FIRST REAL BUSINESS OR SCHOOL ONBOARDING until the automated acceptance workflow passes on the reviewed commit and the owner completes the external deployment, approval, billing, payment, privacy and recovery gates above.** Demo seed success is not production onboarding approval.

## Evidence record template

For each release, record the commit SHA, UTC run timestamp, workflow URL, exact command, pass/fail/skip counts, disposable database name (never its credentials), business and school acceptance results, current deployed SHA, health response, provider evidence references (redacted), backup/restore result, reviewer and remaining blockers. Never store passwords, tokens, callback URLs containing secrets, personal student data or full payment payloads in the report.
