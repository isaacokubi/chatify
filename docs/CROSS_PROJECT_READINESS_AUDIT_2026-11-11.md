# Cross-project readiness audit — Global Tours to Chatify

**Audit date:** 2026-11-11  
**Reference:** [Global Tours repository](https://github.com/isaacokubi/hussein-mboya-tours)  
**Target:** Chatify  
**Target branch:** `audit/first-business-school-readiness-2026-11`  
**Decision:** Chatify source-level first-workspace acceptance improvements are prepared in PR #92; verification and external go-live gates remain pending.

## Reference repository findings

The Global Tours repository was reviewed through its current README, documentation index, production-readiness record, first-tenant acceptance guide, testing guide, latest commit history and recent implementation diffs.

### Engineering and release controls found in Global Tours

1. **Evidence must be commit-specific.** Unit tests, database integration, frontend builds, browser E2E, provider acceptance and production deployment are reported separately.
2. **Database tests are opt-in and isolated.** Destructive tests use dedicated test URIs and reject the production database; missing integration configuration is recorded as skipped, not passed.
3. **First-tenant acceptance is explicit.** It covers tenant creation, admin/customer access, tenant-scoped records, cross-tenant denial and transactional flows.
4. **Demo data is controlled.** Canonical accounts are derived from the seed; staging and production-disposable operations require exact operator authorization and target checks.
5. **Production account checks are read-only.** Login and GET-only checks are separated from seeding or data mutation.
6. **Rate limits are respected.** The 28-account verification matrix waits for the full login window and retries without bypassing the limiter.
7. **CI artifacts are diagnostic evidence.** Reports are uploaded from the correct paths; failures retain useful diagnostics.
8. **Health checks are bounded.** A database connection alone is not readiness when startup migrations are still running; probes retry a legitimate startup 503 and use monotonic timing for latency.
9. **Provider callbacks are not trusted by initiation status alone.** Correlation, provider status, tenant context, idempotency and settlement evidence are required.
10. **External launch gates remain visible.** A green CI result does not certify deployed SHA, real payment callbacks, eTIMS/KRA, SMTP, browser/mobile acceptance or production restore.

### Reference status must not be overstated

Global Tours' production-readiness document still records **NOT PRODUCTION READY** because its production API smoke returned HTTP 503, deployed SHA/runtime cause were unknown, website smoke was skipped, and the protected production archive restore was unverified. Its 2026-11-10 testing guide reports 322 backend tests (317 passed, 0 failed, 5 skipped), `check:all` and client lint/build passed, while 16 Playwright tests were discovered but not run. Those are historical, scoped results—not proof of a production launch.

Recent Global Tours changes on 2026-11-11 also add:
- canonical 28-account matrix coverage;
- retry after rate limiting without bypassing it;
- guarded staging seed and explicit production-disposable seed authorization;
- a separate read-only production demo-account matrix;
- bounded startup readiness retry;
- monotonic production monitoring latency;
- Resend-compatible base64 invoice attachment handling.

## What was adapted to Chatify

| Global Tours control | Chatify adaptation |
|---|---|
| First tenant acceptance | Separate first-business approval and first-school verification acceptance in the guarded MongoDB API integration test |
| Tenant role/isolation checks | Business owner/manager membership checks and school admin/staff/parent/student visibility checks |
| Safe demo seed | New tests for development-only mode, explicit confirmation, production DB rejection, unclassified DB acknowledgement, password bounds and dry-run |
| Canonical account matrix | Enhanced read-only eight-account smoke validates exactly one demo business and one demo school, expected membership, seven catalogue items and six linked students |
| Rate-limit-safe matrix | Login smoke respects `Retry-After` / `RateLimit-Reset` and waits rather than bypassing the 15-minute login limiter |
| Documentation/evidence ledger | New onboarding runbook and explicit pending verification note in `docs/TEST_RESULTS.md` |
| Production boundaries | Business invoice/storefront settlement, school/merchant Daraja, backup/restore, signed release and Kenya privacy review remain separate blockers |

## Chatify architecture distinctions

Chatify does not implement the same domain model as Global Tours and this audit does not claim that it does:

- Business workspaces use `BusinessOrganization` ownership and organization-member roles.
- School workspaces use a separate school verification request, `SchoolWorkspace` and school membership roles.
- Business onboarding is created as pending and requires platform-admin review. It also starts with workspace setup billing required.
- School onboarding starts with a verification request. Only an authorized reviewer creates the workspace and grants the requester admin membership; direct `POST /api/schools` is disabled.
- The one-business/one-school seed directly inserts demo records for demonstration. It does not exercise the real approval/verification path and must never be used to onboard real customers.

The relevant Global Tours controls were adapted to these existing Chatify boundaries; travel booking, supplier, fleet, eTIMS and tour-tenant features were not copied.

## Chatify findings and remaining blockers

### Source-level findings

- The repository already contains one demo business and one demo school with seeded role-linked accounts and relationship checks.
- Business approval and school verification endpoints exist; the new integration assertions cover their real API paths.
- The existing demo smoke test checked authentication and generic resource reads but did not verify the one-business/one-school membership counts or the linked school student set. The updated script adds those read-only checks.
- The demo seed is deliberately development-only and refuses production-named databases. It still needs a disposable database execution record on the reviewed branch.

### Must remain blocked until evidence exists

1. **CI database integration:** current Chatify CI does not configure `CHATIFY_MONGO_TEST_URI`; normal CI may skip the destructive MongoDB test. A dedicated disposable MongoDB service/URI must run the test before calling this gate passed.
2. **Current branch verification:** PR #92 has pending test verification. No branch test result is claimed in this audit.
3. **Real business onboarding:** create a real owner account, submit the business workspace, review it with a platform admin, confirm setup billing independently, then verify business owner/manager permissions.
4. **Real school onboarding:** submit the school's verification request, validate official details, approve it with an authorized reviewer, then add staff/parents and verify linked student visibility.
5. **Business payments:** merchant invoice/storefront settlement remains blocked where merchant-scoped settlement is not implemented. Do not route these charges through the platform shortcode.
6. **School and merchant Daraja:** provider credentials, HTTPS callback delivery, query/callback correlation, receipt and balance idempotency must be verified in the appropriate sandbox. No live-money test is a substitute.
7. **Deployment and operations:** verify current deployed SHA, HTTPS/CORS, health/readiness, logs and alerts, secrets rotation, encrypted off-site backup and isolated restore.
8. **Mobile release:** Flutter tests/builds do not equal signed Android release or physical-device acceptance.
9. **Privacy and legal:** review Kenyan controller/processor roles, ODPC registration/exemption, student/guardian consent and child safeguards, retention/deletion, and any applicable payment-service authorization with the responsible adviser.

## Final status

**Global Tours:** useful reference engineering controls; its own production-readiness record remains NOT PRODUCTION READY.  
**Chatify source changes:** prepared on the audit branch and submitted as draft PR #92.  
**Chatify automated verification:** PENDING.  
**First real business onboarding:** NOT YET CERTIFIED.  
**First real school onboarding:** NOT YET CERTIFIED.  
**Live payment and production operations:** NOT VERIFIED.

Do not merge or onboard real customer/student data based solely on this audit document. First run the new disposable database acceptance, review its report, close the external gates, and update the dated evidence record for the exact release commit.
