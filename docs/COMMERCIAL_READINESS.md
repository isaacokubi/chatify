# Chatify Commercial Readiness — Acceptance Matrix

Updated against `main` on 2026-10-15. CI and external-provider acceptance are tracked separately; see current GitHub Actions runs.

This document is a verification ledger, not a claim that Chatify is commercially ready. Statuses reflect repository documentation and metadata reviewed during this audit. A feature is not considered production-verified merely because an adapter or endpoint exists.

## Status definitions

- **PASS** — implementation and relevant automated or end-to-end verification were inspected and passed.
- **PARTIAL** — some implementation exists, but one or more acceptance criteria remain.
- **BLOCKED** — requires external credentials, provider approval, infrastructure or an owner decision.
- **NOT TESTED** — no execution evidence was available in this audit.
- **NOT IMPLEMENTED** — no sufficient implementation evidence was found.

## Existing product baseline

| Area | Initial status | Evidence / notes |
|---|---|---|
| Flutter mobile client | PARTIAL | `mobile/`; core chat, memory, business workspace, public Stores search and storefront publication controls exist. GitHub Actions ran Flutter analysis and tests successfully at commit `e713fe1b`; the latest storefront-control change is queued for re-verification. |
| Express/Socket.IO API | PARTIAL | `server/`; Node.js >=22, Express 5 and MongoDB/Mongoose. |
| Authentication and direct messaging | PARTIAL | Existing product documentation describes JWT-protected REST and Socket.IO, password hashing and membership checks; production security still requires test verification. |
| Memory Cards and message expiry | PARTIAL | Core differentiators are documented; expiry is application-level hiding/removal, not cryptographic erasure. |
| Business workspace and business APIs | PARTIAL | `docs/BUSINESS_PLATFORM.md` documents organizations, catalogue, CRM-related records, quotations, invoices, tasks, suppliers, workflows and enterprise records. This does not prove all journeys are complete. |
| Invoice-linked M-Pesa | PARTIAL / BLOCKED for live use | Mock and Daraja adapters are documented. Production requires approved credentials and real callback verification. |
| Stripe / PayPal hosted checkout | PARTIAL / BLOCKED for live use | Hosted checkout and webhook paths are documented; provider account eligibility, live credentials and end-to-end production callbacks remain external prerequisites. |
| International tax profiles | PARTIAL | Configurable profiles exist; jurisdictional tax rules and invoice compliance require independent review. |
| Workflow runner | PARTIAL | Allow-listed actions and test mode are documented; durable queues, retries and dead-letter monitoring remain necessary for critical workloads. |
| Public business marketplace | PARTIAL | Public business/product search APIs, bounded pagination, a Flutter Stores search interface, storefront opening, and checkout entry exist. Owners/managers can publish or hide the storefront using the Business workspace; `settings.storefrontPublished=false` is enforced across discovery, storefront, enquiry and checkout routes. Public checkout and web storefront polish, route-level security tests, and customer guest checkout remain open. |
| Shared inbox real-time UI | NOT IMPLEMENTED / PARTIAL | Existing documentation identifies real-time shared-inbox/customer case-room UI as future work. |
| Subscription lifecycle and enforceable entitlements | PARTIAL / BLOCKED for paid billing | Server-side quotas exist; signed HMAC lifecycle-event handling and plan transitions were added. Hosted checkout, native provider signatures, renewals and live payment reconciliation remain blocked/unverified. |
| Inventory ledger and procurement | NOT TESTED | Must verify stock reservations, concurrency, movements, purchasing and tenant boundaries before commercial claims. |
| CRM pipeline | PARTIAL | Customer CSV preview/import is implemented with tenant scoping, duplicate checks and plan quotas. Full visual pipeline, conversions and reminders remain open. |
| Support desk and delivery operations | PARTIAL | Tenant-scoped SLA reporting and a secret-protected escalation job were added; customer portal service requests are supported by APIs. Scheduler, notifications, fulfilment and UI journeys remain to verify. |
| Business Copilot | PARTIAL / NOT TESTED | Deterministic memory suggestions exist; authorized retrieval, record citations, action confirmation and AI safety require separate acceptance tests. |
| Supplier marketplace | PARTIAL / NOT TESTED | Supplier records and quotes are documented; public discovery, offers, purchase requests and secure supplier workflows require verification. |
| Public versioned API and integrations directory | PARTIAL | A read-only v1 storefront catalogue API now uses one-time, hashed, revocable, expiring tenant API keys with a `catalog:read` scope. Reliable outbound webhooks, more scopes and integrations directory UI remain open. |
| Internationalization and custom domains | PARTIAL / NOT TESTED | Currency/tax configuration and industry configuration are documented; locale-complete UI, domain ownership verification and safe tenant hostname resolution require verification. |
| Backups and disaster recovery | PARTIAL / NOT VERIFIED | Manual MongoDB archive/checksum and guarded restore scripts plus an operations runbook exist. Scheduled off-site encrypted backup, alerts and a successful isolated restore drill are infrastructure-owned and unverified. |
| Monitoring and incident response | PARTIAL | `GET /api/status` is documented as a basic API/database health endpoint, not historical monitoring or a full incident telemetry system. |
| Enterprise SSO and advanced security | NOT IMPLEMENTED / NOT TESTED | Must not be represented as available until implemented and verified. |

## Mandatory acceptance gates

These gates must pass before describing the platform as commercially ready:

- [ ] Public customers can browse published businesses and catalogues without business-admin access. (API/UI implemented; automated route acceptance and guest checkout remain to verify.)
- [ ] Public endpoints expose only explicitly public fields and never expose unpublished tenant records.
- [ ] Customer order, quotation, cancellation, fulfilment and notification journeys work end to end.
- [ ] Inventory changes are transactionally consistent and cannot oversell under concurrency.
- [ ] Issued invoices preserve historical snapshots; partial payments, receipts, refunds and statements reconcile.
- [ ] Forged, duplicate, delayed and mismatched payment callbacks are safely handled and idempotent.
- [ ] Live payment providers are verified using provider dashboards and actual test/live callbacks as appropriate.
- [ ] Tenant isolation and role permissions are covered by automated regression tests for every business module.
- [ ] Team membership revocation and conversation assignment/handover are enforced server-side.
- [ ] CRM, inventory, support, delivery and exports are tenant-scoped and permission-checked.
- [ ] Subscription entitlements are enforced by the backend and billing events are idempotent.
- [ ] AI-assisted data access respects the signed-in user's organization and permissions.
- [ ] Public API credentials are scoped, revocable, rotatable and never revealed again after creation.
- [ ] Webhook signatures, retries, event deduplication and delivery history are tested.
- [ ] Import/export validates input, reports errors and does not duplicate or overwrite unrelated tenant data.
- [ ] Locale, currency, timezone and tax behavior are configurable and tested without treating Kenya's rules as universal.
- [ ] Custom domains require verified ownership and validated hostname-to-tenant mapping.
- [ ] Backups are scheduled, protected and restored successfully in a safe non-production environment.
- [ ] CI, backend tests, Flutter analysis/tests/build and dependency review have actual recorded results.

## Safe execution protocol

1. Work on `main` without force-pushing or rewriting published history.
2. Inspect current files and existing tests before editing a module.
3. Make a focused change that extends existing models and routes rather than creating duplicates.
4. Add tests for authorization, tenant isolation, validation, duplicate requests and failure paths.
5. Run the narrow test first, then the complete backend checks and Flutter checks when tooling is available.
6. Do not use production databases for test fixtures, destructive migrations or seeding.
7. Keep provider secrets in deployment secret settings; `.env.example` contains placeholders only.
8. Record the exact command, result, commit and external blocker for each checkpoint.
9. Mark a gate PASS only with evidence; otherwise retain PARTIAL, BLOCKED or NOT TESTED.

## Local audit run — 2026-10-15

The repository was fast-forwarded on `main` from `6de3471` to `99a354a` before inspection. The working tree was clean before the audit. Local verification was then run against the changed working tree:

- Backend dependencies installed with `cd server && npm ci` (295 packages; npm reported 0 vulnerabilities).
- Backend `npm test`: 101 passed, 0 failed, 0 skipped. This includes HTTP startup/authentication and production database-configuration regression tests.
- Backend `npm run lint` and `bash -n scripts/backup-mongodb.sh scripts/restore-mongodb.sh`: passed.
- Backend `npm audit --omit=dev`: 0 vulnerabilities.
- `dart format --output=none --set-exit-if-changed .`: passed; Flutter analysis: no issues; Flutter tests: 13 passed.
- `flutter build web`: passed and produced the standard web build. The optional WebAssembly dry run reported an incompatibility in the current `socket_io_common` dependency; this did not prevent the JavaScript web build.
- Android debug APK build was intentionally left incomplete at the project owner's request. No APK build result is claimed.
- No production database or provider credentials were used. Production database indexes, live payment callbacks, backup restoration, provider delivery, remote CI status and production deployment remain unverified.

The API startup regression test's cold-start wait was raised from six to thirty seconds after the locked dependency graph took about nineteen seconds to initialize locally. The API then started and returned the expected JSON authentication errors. Production startup now fails with a clear error when `MONGODB_URI` is absent instead of starting an unusable service. These changes do not claim a production deployment.


## Additional operational tooling committed

The repository now includes a private compressed MongoDB archive script and a guarded non-production restore script with checksum verification. This improves the backup/restore runbook but does not count as an executed production backup, off-site replication, or a successful recovery drill. Those remain deployment-operator acceptance gates.


## Latest implementation notes

- Public storefront APIs and marketplace search now honor the optional `settings.storefrontPublished` flag. Omitting the flag preserves existing storefront visibility; setting it to `false` hides the business from public discovery and rejects storefront viewing, enquiry submission and checkout.
- The Flutter Stores screen is connected to the public business and product search APIs with keyword, category, country and town/branch filters.
- The customer statement endpoint and plan quota checks have unit coverage in the Node test suite. These tests do not replace live payment, database migration, deployment or restore drills.


## Verification record

- Node API tests and syntax checks passed in GitHub Actions for commit `4a20d5a6` and later quality-check runs.
- Flutter analysis and tests passed in GitHub Actions for commit `e713fe1b` after fixing three analyzer findings in the marketplace screen.
- Storefront publication enforcement and its Business workspace toggle were added after that successful run; verify the newest commit in [GitHub Actions](https://github.com/isaacokubi/chatify/actions) before release.
- No live provider credentials, production database, deployment console, or infrastructure scheduler were available in this repository-editing session. Live payment callbacks, KRA eTIMS approval, recurring subscription billing, scheduled/off-site backup, restore drills, custom-domain DNS verification and production deployment are not claimed as complete.
- Android release artifacts now require an externally managed signing keystore and secrets. A company-owned Android application ID still needs to be selected before Play Store publication.


## Additions after the initial readiness review

- Added a signed subscription lifecycle boundary, but not a hosted billing checkout or a provider-certified subscription integration.
- Added support SLA reporting/escalation, authenticated customer order/request APIs, verified-purchase review moderation, customer CSV preview/import, and a read-only v1 catalogue API with revocable keys.
- These additions have focused Node tests. The latest workflow status should be checked before release; repository access does not establish production database indexes, live provider behavior, scheduled-job configuration, or Flutter UI coverage for the new API journeys.
