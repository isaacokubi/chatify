# Chatify Database Schema Guide

The detailed database notes are in [DATABASE.md](DATABASE.md); this guide adds the school/business tenant model and review checklist.

## Core account and messaging data

The platform uses MongoDB/Mongoose. Core records include users, conversations, messages, memories, password resets and payment records. Participant links, reactions, read state, notification preferences and FCM device tokens are embedded where appropriate. Device tokens and secret material must not be returned by ordinary user APIs.

## School domain

The school domain is implemented in `server/src/school.js` and its related fee helpers. The domain includes:
- school workspace identity and creator/owner;
- active school memberships with canonical roles (`admin`, `staff`, `parent`);
- student records and guardian linkage;
- class/academic records;
- attendance;
- fee structures, fee balances, payments and receipts;
- school messages and verification requests.

Every school-owned query must include the authenticated school ID and apply role/linked-student visibility. A parent must not be able to list all families or retrieve an unrelated student's records by substituting an identifier.

## Business domain

The business domain is implemented in `server/src/business.js` and supporting business modules. Core organization-owned records include:
- organizations, owner ID and member roles;
- branches;
- catalogue items;
- customers;
- documents/invoices/orders and payment references;
- tasks and cases;
- suppliers, workflows, audit records and enterprise records;
- provider checkout/reconciliation records where enabled.

Business collections are scoped by `organizationId`. The owner is established by the server from the authenticated user; member roles control manager, contributor and finance operations.

## Indexes and consistency

Review the actual schema declarations and migration scripts before changing indexes. Preserve unique email, tenant-scoped unique identifiers, payment/idempotency keys, provider references and query indexes. Financial history should use supported lifecycle/archive transitions rather than destructive deletion.

## Migration and test rules

- Use additive, reversible migrations where possible.
- Never run test seeds or restore scripts against production.
- Use a dedicated disposable MongoDB database/replica set for integration tests.
- Verify index creation and transaction requirements on the actual Atlas tier/cluster configuration.
- Capture before/after record counts and checksums for controlled migrations.
- Test duplicate requests, retries and concurrent writes for payment and membership flows.
