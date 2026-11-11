# Chatify API Reference Index

The canonical endpoint and request semantics reference is [API.md](API.md). This page organizes the domain routes for onboarding and test planning; it does not replace the route handlers or API.md.

## Authentication and platform

- `POST /api/auth/register`, `POST /api/auth/login`, `GET /api/auth/me`
- Password change/reset endpoints and platform-admin routes are documented in [API.md](API.md).
- Protected APIs require the bearer token and enforce server-side identity/role checks.

## School workspace

- `GET /api/schools` — active memberships and owner indicator.
- School verification request/review flow — required for production school creation; direct legacy school creation is disabled.
- `GET /api/schools/:schoolId/members` and `POST /api/schools/:schoolId/members`.
- `GET /api/schools/:schoolId/students`, with admin-only create/update/transfer operations.
- `GET /api/schools/:schoolId/attendance`; marking/correction requires permitted school roles.
- `GET /api/schools/:schoolId/academics`.
- `GET /api/schools/:schoolId/fees`, `/fee-balances`, `/fee-structures`, receipt and payment routes.
- Messages, classes, receipts, billing and verification routes are implemented in `server/src/school.js`.

## Business organization

- `POST /api/business/organizations` — creates an organization with the authenticated user as owner.
- `GET /api/business/organizations` — organizations owned by or shared with the authenticated user.
- `GET /api/business/organizations/:orgId/dashboard` — organization-scoped summary metrics.
- `GET/POST/PATCH/DELETE /api/business/organizations/:orgId/customers`.
- `GET/POST/PATCH/DELETE /api/business/organizations/:orgId/catalog`.
- Documents, tasks, cases, branches, workflows, audit logs, export, subscriptions, POS and payment routes are implemented in `server/src/business.js` and related modules.

## Messaging and real-time

Conversation, message, Socket.IO, device-token and payment event routes are documented in [API.md](API.md). Socket room membership must be authorized server-side; client navigation is not a security boundary.

## API change policy

For every new route, document:
- authentication requirement;
- canonical role and workspace membership requirement;
- tenant-scoped query filter;
- input schema and size limits;
- response allow-list and sensitive-field redaction;
- pagination and rate limits;
- audit/idempotency behavior for writes;
- tests for allowed and denied callers.

Do not infer a route's production readiness from this index. Verify the exact implementation and tests on the release commit.
