# Chatify Business Platform

This document describes the first connected implementation of the business-focused Chatify roadmap. It extends the existing chat, Memory Cards and payment API rather than replacing them.

## Mobile entry point

The Flutter app has a **Business** tab. It can create/select a business workspace and manage:
- workspace and industry selection;
- business dashboard metrics;
- products and services;
- customer records;
- quotations;
- tasks and follow-ups;
- a Tools panel for tax profiles, text/voice translation, Business Memory suggestions, consent-gated WhatsApp/SMS, scheduled workflows, offline sync review, and invoice issue/M-Pesa/eTIMS actions.

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


## Extended integrations and production configuration

### International tax profiles
- Configure the organization's tax profile with `PATCH /api/business/organizations/:orgId/tax-profile` using `country`, `currency`, `mode` (`exclusive`, `inclusive`, `none`), `rate`, and optional `taxLabel` / `registrationNumber`.
- Document totals use the stored workspace profile, apply per-line percentage discounts, and distinguish inclusive from exclusive tax. This is a calculation tool, not tax/legal advice; confirm rates, exemptions, rounding and invoice rules with the tax authority or accountant in each jurisdiction.
- Currency support is deliberately allow-listed. Configure a supported currency before issuing documents.

### Invoice-linked M-Pesa
- `POST /api/business/organizations/:orgId/documents/:documentId/mpesa-stk` with `{ "phone": "07..." }` initiates STK for the invoice's outstanding whole-KSh balance.
- A payment is linked to the invoice and only a verified Daraja callback updates the confirmed paid balance. The mock provider remains a simulation and is clearly identified as such. M-Pesa is currently KES-only.

### KRA eTIMS gateway adapter
- `POST /api/business/organizations/:orgId/documents/:documentId/etims-submit` sends issued invoices to an explicitly configured HTTPS gateway using `ETIMS_SUBMISSION_URL`, `ETIMS_API_TOKEN`, and `ETIMS_TAXPAYER_PIN`.
- eTIMS API and onboarding differ by integration route and taxpayer. This adapter is a gateway contract, not a claim that an arbitrary endpoint is KRA's official endpoint or that an HTTP success equals fiscal acceptance. Do not configure it until the gateway is authorized and its request/response mapping has been tested. Results remain pending verification.

### Consent-gated customer communications
- Record opt-in using `PATCH /api/business/organizations/:orgId/customers/:customerId/messaging-consent` with `{ "consent": true }`.
- Send with `POST /api/business/organizations/:orgId/communications/send` using `customerId`, `channel` (`whatsapp` or `sms`) and `message`.
- WhatsApp Cloud API uses `WHATSAPP_ACCESS_TOKEN` and `WHATSAPP_PHONE_NUMBER_ID`. SMS uses Twilio credentials. Credentials are server-only; an accepted API request does not guarantee delivery. Collect and honor consent and opt-outs in accordance with local laws and provider policies.

### AI translation and voice translation
- `POST /api/business/organizations/:orgId/translate` accepts `text`, `targetLanguage`, optional `sourceLanguage`, and mandatory `consent: true`.
- `POST /api/business/organizations/:orgId/voice-translate` accepts base64 `audioBase64`, `mimeType`, `targetLanguage`, and mandatory `consent: true`. Audio is limited to 11 MB and must be sent only where the user has consented.
- Configure `AI_API_KEY`, optional `AI_API_BASE_URL`, `AI_TEXT_MODEL`, and `AI_AUDIO_MODEL`. This requires an OpenAI-compatible endpoint with transcription and chat-completions APIs. No audio/text is sent when the service is unconfigured.

### Business Memory suggestions
- `POST /api/business/organizations/:orgId/memory-candidates` accepts text up to 5,000 characters and returns deterministic task/payment/date/business-context suggestions. Suggestions are not saved automatically; review them before creating Memory Cards or tasks.

### Offline-first sync
- `POST /api/business/organizations/:orgId/sync` accepts up to 50 idempotent edits for existing customer, catalogue, task and support-case records.
- Every mutation needs a safe unique `mutationId` and the record's `baseUpdatedAt`. A stale edit returns the current server record as a conflict instead of silently overwriting it. Creates and binary attachments are not part of this endpoint.

### Scheduled workflows
- Schedule workflows using `trigger: "schedule"` and `scheduleEveryMinutes` (5–10,080 minutes). They remain disabled until a test-only run is recorded, and must be explicitly enabled by a manager.
- A process-local minute tick executes due workflows using a database compare-and-set; multi-instance deployments should additionally configure a single external cron calling `POST /api/internal/business/workflows/tick` with `Authorization: Bearer BUSINESS_WORKFLOW_CRON_SECRET`. Only allow-listed actions run, customer messages require recorded opt-in, and tests do not send messages or move money.
- For high-volume or critical business automation, use a durable queue/worker and monitor retries, delivery receipts, and dead letters before relying on scheduled actions for operations.
