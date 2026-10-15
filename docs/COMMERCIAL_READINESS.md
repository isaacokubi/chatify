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
| Flutter mobile client | PARTIAL | `mobile/`; core chat and memory product exists. This audit did not execute Flutter tooling. |
| Express/Socket.IO API | PARTIAL | `server/`; Node.js >=22, Express 5 and MongoDB/Mongoose. |
| Authentication and direct messaging | PARTIAL | Existing product documentation describes JWT-protected REST and Socket.IO, password hashing and membership checks; production security still requires test verification. |
| Memory Cards and message expiry | PARTIAL | Core differentiators are documented; expiry is application-level hiding/removal, not cryptographic erasure. |
| Business workspace and business APIs | PARTIAL | `docs/BUSINESS_PLATFORM.md` documents organizations, catalogue, CRM-related records, quotations, invoices, tasks, suppliers, workflows and enterprise records. This does not prove all journeys are complete. |
| Invoice-linked M-Pesa | PARTIAL / BLOCKED for live use | Mock and Daraja adapters are documented. Production requires approved credentials and real callback verification. |
| Stripe / PayPal hosted checkout | PARTIAL / BLOCKED for live use | Hosted checkout and webhook paths are documented; provider account eligibility, live credentials and end-to-end production callbacks remain external prerequisites. |
| International tax profiles | PARTIAL | Configurable profiles exist; jurisdictional tax rules and invoice compliance require independent review. |
| Workflow runner | PARTIAL | Allow-listed actions and test mode are documented; durable queues, retries and dead-letter monitoring remain necessary for critical workloads. |
| Public business marketplace | PARTIAL | Public business/product search APIs, bounded pagination, a Flutter Stores search interface, storefront opening, and checkout entry exist. Publication can be disabled with `settings.storefrontPublished=false`; public checkout and web storefront polish, route-level security tests, and customer guest checkout remain open. |
| Shared inbox real-time UI | NOT IMPLEMENTED / PARTIAL | Existing documentation identifies real-time shared-inbox/customer case-room UI as future work. |
| Subscription lifecycle and enforceable entitlements | NOT IMPLEMENTED | Existing documentation says usage is informational and does not claim plan limits or recurring subscription billing are enforced. |
| Inventory ledger and procurement | NOT TESTED | Must verify stock reservations, concurrency, movements, purchasing and tenant boundaries before commercial claims. |
| CRM pipeline | PARTIAL / NOT TESTED | Existing business records may cover leads/customers; full pipeline, conversion, reminders, reporting and end-to-end journey require verification. |
| Support desk and delivery operations | PARTIAL / NOT TESTED | Record types exist in the documented business model; operational screens, SLA logic, notifications and acceptance journeys need verification. |
| Business Copilot | PARTIAL / NOT TESTED | Deterministic memory suggestions exist; authorized retrieval, record citations, action confirmation and AI safety require separate acceptance tests. |
| Supplier marketplace | PARTIAL / NOT TESTED | Supplier records and quotes are documented; public discovery, offers, purchase requests and secure supplier workflows require verification. |
| Public versioned API and integrations directory | NOT TESTED | Existing integration endpoints do not by themselves establish a versioned public API, scoped keys, webhook delivery guarantees or integration catalogue. |
| Internationalization and custom domains | PARTIAL / NOT TESTED | Currency/tax configuration and industry configuration are documented; locale-complete UI, domain ownership verification and safe tenant hostname resolution require verification. |
| Backups and disaster recovery | NOT IMPLEMENTED / NOT VERIFIED | A script or policy is not accepted as proof of scheduled backups or successful restoration. |
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

## Audit limitation

This checkpoint used the connected GitHub repository/file interface. It can inspect and commit text files but does not provide a local shell, database, Flutter SDK, Node runtime, deployment dashboard or payment-provider credentials. Consequently, no local test suite, production build, database migration, live payment, backup restoration or deployment check is claimed as executed by this checkpoint.


## Additional operational tooling committed

The repository now includes a private compressed MongoDB archive script and a guarded non-production restore script with checksum verification. This improves the backup/restore runbook but does not count as an executed production backup, off-site replication, or a successful recovery drill. Those remain deployment-operator acceptance gates.


## Latest implementation notes

- Public storefront APIs and marketplace search now honor the optional `settings.storefrontPublished` flag. Omitting the flag preserves existing storefront visibility; setting it to `false` hides the business from public discovery and rejects storefront viewing, enquiry submission and checkout.
- The Flutter Stores screen is connected to the public business and product search APIs with keyword, category, country and town/branch filters.
- The customer statement endpoint and plan quota checks have unit coverage in the Node test suite. These tests do not replace live payment, database migration, deployment or restore drills.
