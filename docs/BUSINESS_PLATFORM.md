# Chatify Business Platform

This document describes the first connected implementation of the business-focused Chatify roadmap. It extends the existing chat, Memory Cards and payment API rather than replacing them.

## Mobile entry point

The Flutter app has a **Business** tab. It can create/select a business workspace and manage:
- workspace and industry selection;
- business dashboard metrics;
- products and services;
- customer records;
- quotations;
- tasks and follow-ups.

The mobile screen calls the authenticated API described below. The other operations are exposed as APIs and can be surfaced in later screens without changing the stored record formats.

## Implemented business API

All private routes require the same Chatify bearer token used by the messaging API. Replace `:orgId` with the organization ID returned from `GET /api/business/organizations`.

| Capability | Routes |
|---|---|
| Workspaces and team access | `GET/POST /api/business/organizations`, `GET/PATCH /api/business/organizations/:orgId`, `POST/DELETE /api/business/organizations/:orgId/members` |
| Multi-branch setup | `POST/PATCH /api/business/organizations/:orgId/branches`, `PATCH /api/business/organizations/:orgId/branches/:branchId` |
| Customer CRM | `GET/POST /api/business/organizations/:orgId/customers`, `PATCH/DELETE /api/business/organizations/:orgId/customers/:customerId` |
| Storefront catalogue and inventory | `GET/POST /api/business/organizations/:orgId/catalog`, `PATCH/DELETE /api/business/organizations/:orgId/catalog/:itemId` |
| Quotations, orders, invoices and receipts | `GET/POST /api/business/organizations/:orgId/documents`, `PATCH /api/business/organizations/:orgId/documents/:documentId/status` |
| Payment recording and reconciliation | `POST /api/business/organizations/:orgId/documents/:documentId/payment-records`, `POST /api/business/organizations/:orgId/documents/:documentId/reconcile-chatify-payment` |
| Tasks, commitments, appointments and deliveries | `GET/POST /api/business/organizations/:orgId/tasks`, `PATCH /api/business/organizations/:orgId/tasks/:taskId`, `POST /api/business/organizations/:orgId/tasks/:taskId/confirm` |
| Shared inbox assignment / shift handover | `GET /api/business/organizations/:orgId/inbox`, `PUT /api/business/organizations/:orgId/inbox/:conversationId` |
| Support and resolution cases | `GET/POST /api/business/organizations/:orgId/cases`, `POST /api/business/organizations/:orgId/cases/:caseId/updates` |
| Suppliers and B2B trade requests | `GET/POST /api/business/organizations/:orgId/suppliers`, `GET/POST /api/business/organizations/:orgId/trade-requests`, `POST /api/business/organizations/:orgId/trade-requests/:requestId/offers` |
| No-code workflow definitions | `GET/POST /api/business/organizations/:orgId/workflows`, `PATCH /api/business/organizations/:orgId/workflows/:workflowId`, `POST /api/business/organizations/:orgId/workflows/:workflowId/test` |
| Business dashboard, search, audit and portability | `GET /api/business/organizations/:orgId/dashboard`, `GET /api/business/organizations/:orgId/search?q=...`, `GET /api/business/organizations/:orgId/audit-logs`, `GET /api/business/organizations/:orgId/export` |
| Public storefront and enquiries | `GET /api/business/storefront/:slug`, `POST /api/business/storefront/:slug/enquiries` |

## Industry editions

Workspace setup supports retail/wholesale, consulting, tourism/hospitality, logistics, construction, salon/personal services, education, agriculture, real estate/property, and other industries. These currently use a shared configurable business data model. They are not yet separate polished industry-specific applications.

## Trust and security rules

- The server derives the signed-in user from the Chatify bearer token. It never accepts an arbitrary owner ID as authority.
- Organization records are scoped to the owner or an explicitly enrolled member. Only owners/admins/managers can change high-impact workspace settings and team membership.
- Document line totals, tax and total are calculated server-side. Document statuses follow a constrained lifecycle.
- Manually recorded cash, bank or M-Pesa payments remain **unverified**. A screenshot or client-supplied paid flag cannot mark an invoice paid.
- Chatify payment reconciliation requires a successful payment with provider callback evidence and prevents reconciling the same payment reference twice.
- Workflows are created disabled. Test mode logs proposed actions without sending messages, executing arbitrary code or moving money.
- Audit records contain actor, action, record type, record ID and a short summary; they intentionally do not copy chat contents or payment credentials.
- Storefront endpoints return active catalogue items only. Public enquiries create a CRM lead, not a verified order or payment.
- Export is restricted to organization managers. Business data should still be handled according to applicable privacy and retention requirements.

## Local validation

From the repository root:

```bash
cd server
npm ci
npm test
npm run lint
```

The focused pure-logic tests in `src/business.test.js` cover business slugs, server-side document totals, lifecycle transitions and the business briefing. A real deployment should additionally test database migrations/index creation, organization isolation, provider callback reconciliation and Flutter web/mobile builds against a non-production database.

## Roadmap items that still require external services or additional implementation

The foundation is in place for these features, but they must not be represented as fully delivered just because the data model can support them:
- live Daraja payment initiation linked to business invoices, eTIMS/KRA integration and country-specific tax compliance;
- automated email/SMS/WhatsApp integrations, with provider approval and supported APIs;
- automatic workflow execution, scheduled reminders and background jobs;
- real-time shared inbox UI and a customer-facing case room;
- translations, voice transcription, cross-language quote confirmation and AI-generated actions;
- verified supplier identity, dispute management and a public multi-business marketplace;
- offline queueing with conflict resolution, push notifications for every business event and robust background synchronization;
- international tax/payment/shipping integrations, region-specific storage, subscriptions and enterprise SSO;
- advanced forecasting and predictive early-warning models.

These need credentials, operational policies, external-provider configuration, product testing and privacy review. Keep mock/test providers as the default until each production integration is deliberately configured.
