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
- a Tools panel for tax profiles, text/voice translation, Business Memory suggestions, consent-gated WhatsApp/SMS, scheduled workflows, offline sync review, and invoice issue/M-Pesa/Stripe/PayPal/eTIMS actions.

The mobile screen calls the authenticated API described below. Advanced operations are available through the Tools panel and authenticated APIs; provider-dependent actions remain disabled until their server credentials are configured.

## Implemented business API

All private routes require the same Chatify bearer token used by the messaging API. Replace `:orgId` with the organization ID returned from `GET /api/business/organizations`.

| Capability | Routes |
|---|---|
| Workspaces and team access | `GET/POST /api/business/organizations`, `GET/PATCH /api/business/organizations/:orgId`, `POST/DELETE /api/business/organizations/:orgId/members` |
| Multi-branch setup | `POST/PATCH /api/business/organizations/:orgId/branches`, `PATCH /api/business/organizations/:orgId/branches/:branchId` |
| Customer CRM | `GET/POST /api/business/organizations/:orgId/customers`, `PATCH/DELETE /api/business/organizations/:orgId/customers/:customerId` |
| Storefront catalogue and inventory | `GET/POST /api/business/organizations/:orgId/catalog`, `PATCH/DELETE /api/business/organizations/:orgId/catalog/:itemId` |
| Quotations, orders, invoices and receipts | `GET/POST /api/business/organizations/:orgId/documents`, `PATCH /api/business/organizations/:orgId/documents/:documentId/status` |
| Payment recording, matching review and reconciliation | `POST /api/business/organizations/:orgId/documents/:documentId/payment-records`, `GET /api/business/organizations/:orgId/documents/:documentId/payment-matching`, `POST /api/business/organizations/:orgId/documents/:documentId/reconcile-chatify-payment` |
| Tasks, commitments, appointments and deliveries | `GET/POST /api/business/organizations/:orgId/tasks`, `PATCH /api/business/organizations/:orgId/tasks/:taskId`, `POST /api/business/organizations/:orgId/tasks/:taskId/confirm` |
| Shared inbox assignment / shift handover | `GET /api/business/organizations/:orgId/inbox`, `PUT /api/business/organizations/:orgId/inbox/:conversationId` |
| Support and resolution cases | `GET/POST /api/business/organizations/:orgId/cases`, `POST /api/business/organizations/:orgId/cases/:caseId/updates` |
| Suppliers and B2B trade requests | `GET/POST /api/business/organizations/:orgId/suppliers`, `GET/POST /api/business/organizations/:orgId/trade-requests`, `POST /api/business/organizations/:orgId/trade-requests/:requestId/offers` |
| No-code workflow definitions | `GET/POST /api/business/organizations/:orgId/workflows`, `PATCH /api/business/organizations/:orgId/workflows/:workflowId`, `POST /api/business/organizations/:orgId/workflows/:workflowId/test` |
| Business dashboard, search, audit and portability | `GET /api/business/organizations/:orgId/dashboard`, `GET /api/business/organizations/:orgId/search?q=...`, `GET /api/business/organizations/:orgId/audit-logs`, `GET /api/business/organizations/:orgId/export` |
| Public storefront and enquiries | `GET /api/business/storefront/:slug`, `POST /api/business/storefront/:slug/enquiries` |

## Enterprise workspace extensions

The Business Tools panel now exposes an **Enterprise workspace** screen for the following organization-scoped APIs. Every private request is authorized against the selected workspace; a user cannot search or mutate another tenant's records by changing the URL.

| Capability | Routes |
|---|---|
| Executive overview and readiness checks | `GET /api/business/organizations/:orgId/enterprise/overview`, `GET /api/business/organizations/:orgId/enterprise/readiness` |
| Permission-aware cross-module search | `GET /api/business/organizations/:orgId/enterprise/search?q=...` searches customers, catalogue items, documents, tasks, cases and enterprise records within that organization |
| Enterprise records | `GET/POST /api/business/organizations/:orgId/enterprise/records`, `PATCH /api/business/organizations/:orgId/enterprise/records/:recordId` |
| Handbook and service-policy acknowledgements | `POST /api/business/organizations/:orgId/enterprise/records/:recordId/acknowledge` |
| Approval and refund/dispute decisions | `POST /api/business/organizations/:orgId/enterprise/records/:recordId/decision` |
| Resolve support cases and incidents | `POST /api/business/organizations/:orgId/enterprise/records/:recordId/resolve` |
| Commitment suggestions | `POST /api/business/organizations/:orgId/enterprise/commitment-suggestions`; suggestions are never automatically converted into tasks |
| Workspace feature preferences and service targets | `GET/PATCH /api/business/organizations/:orgId/enterprise/settings` |
| Usage visibility | `GET /api/business/organizations/:orgId/enterprise/usage` |
| Immutable financial close snapshots | `GET /api/business/organizations/:orgId/enterprise/financial-periods`, `POST /api/business/organizations/:orgId/enterprise/financial-periods/close` |
| Enterprise record CSV | `GET /api/business/organizations/:orgId/enterprise/export` (finance/manager roles only) |
| Expiring customer links | `POST/GET /api/business/organizations/:orgId/enterprise/shares`, `DELETE /api/business/organizations/:orgId/enterprise/shares/:shareId`, public `GET /api/business/public-shares/:token` |
| Restricted platform overview | `GET /api/platform/admin/overview`; requires the user ID to be explicitly configured in `CHATIFY_SUPER_ADMIN_USER_IDS` |

Enterprise record types cover handbook/procedure, notifications, approvals, refunds, credit profiles, project rooms, supplier quotes, service policies, delivery proof, disputes, consent records, support cases, incidents, integrations, migrations, recovery plans, commitments, response targets, subscription notes, financial period closes, supplier comparisons, customer portal records, transaction-linked review records and service-recovery plans. Records are organization-scoped, validated, auditable and available from the Business Tools UI. High-impact requests start pending, and approval is restricted to owner/admin/manager/finance roles; a request creator cannot approve their own request.

The readiness endpoint checks profile, team, catalogue, customers, support contact and M-Pesa recipient setup. Finance roles can close a date range into an immutable invoice snapshot; later corrections must be recorded separately rather than editing the closed snapshot. Usage is currently informational; the API explicitly does **not** claim that plan limits are enforced or that subscription renewals are billed. The platform overview is a starting point for a restricted Super Admin console, not a full service-monitoring/incident telemetry system.


### External sharing and payment-matching rules

Customer links use a high-entropy random token while the database stores only its SHA-256 hash. Links expire (1 hour to 30 days) and can be revoked by authorized workspace roles. Shared invoice views expose only document totals, line items, status and due date; they do not expose internal notes, customer phone numbers or payment credentials. Shared enterprise views are limited to customer-facing project, portal, policy and delivery record types, and expose only an explicitly supplied public description and customer updates. Set the API's public URL in the mobile build's `CHATIFY_API` value so the UI can create a usable absolute link.

Payment matching confidence is advisory triage only. A manually entered reference with a high-looking confidence value remains unverified. Only the existing provider-confirmed reconciliation flow updates confirmed paid totals or marks an invoice paid. Enterprise usage counts are informational; plan limits, recurring subscription billing, full backup orchestration, a public status page and transaction-linked review moderation still require dedicated production implementation before being sold as fully operational services.

## Public service status

`GET /api/status` returns a cache-disabled, secret-free operational summary for the HTTP API and MongoDB dependency. It returns HTTP 503 while MongoDB is disconnected. Real-time messaging and payment providers are explicitly marked unverified rather than being presented as healthy without independent probes. This is a basic status endpoint, not yet a historical incident timeline or external monitoring integration.

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

## Remaining work and production prerequisites

The following distinctions are important; implemented adapters are not the same as activated and production-verified services:
- **Daraja/M-Pesa:** invoice-linked STK flow and callback reconciliation are implemented, but live use requires Safaricom production credentials and end-to-end testing.
- **KRA eTIMS:** a configurable gateway adapter is implemented. The taxpayer must obtain the appropriate KRA onboarding and use an authorized gateway/API contract; this repository does not claim that an arbitrary URL is KRA's official endpoint.
- **Messaging and language services:** WhatsApp Cloud API, Twilio SMS, text translation and audio transcription/translation adapters are implemented, but provider credentials, sender approval, consent and provider-specific testing are required.
- **Workflows:** a scheduled allow-listed runner and protected cron endpoint are implemented. Multi-instance deployments should use one external scheduler; high-criticality automation still needs a durable queue, retries and dead-letter monitoring.
- **Offline sync:** on-device queued creates and version-checked server sync are implemented for customers, catalogue items, tasks and support cases. Offline edits, attachments, conflict merge UI and guaranteed background delivery remain future work.
- **International billing:** configurable tax profiles, Stripe Checkout and PayPal Orders v2 are implemented. Confirm supported currencies, tax law, refunds, disputes, payment-provider eligibility and live webhooks before accepting real payments.
- **Still future work:** real-time shared-inbox and customer case-room UI, verified supplier identity, dispute management, public multi-business marketplace, region-specific storage, subscriptions, enterprise SSO, full push notifications for every business event, cross-language quote confirmation, autonomous AI actions, advanced forecasting and predictive early-warning models.

Use sandbox/test credentials first. Production activation requires operational policies, privacy review, monitoring, provider verification and end-to-end tests; do not claim a provider is live until its production configuration and actual callbacks have been verified.

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


### International hosted payments (Stripe Checkout)
- Configure `STRIPE_ENV=test` for testing or `STRIPE_ENV=production` for live mode, plus `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_SUCCESS_URL`, and `STRIPE_CANCEL_URL` on the server. Test/live key prefixes and signed event `livemode` must match the configured mode. Never put these values in Flutter or source control.
- `POST /api/business/organizations/:orgId/documents/:documentId/stripe-checkout` creates a hosted checkout for the outstanding balance of an issued invoice and returns the checkout URL. The mobile app opens that URL outside Chatify.
- Configure the Stripe webhook to call `POST /api/business/payments/stripe/webhook` and subscribe to `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, and `checkout.session.expired`.
- The server verifies the Stripe signature against the raw request body and validates checkout ID, metadata, currency, and minor-unit amount before reconciling the invoice. Redirecting back to Chatify is not proof of payment.
- Test with Stripe test-mode keys and a test webhook secret first. Production keys, webhook delivery, refunds, disputes, chargebacks, tax handling and provider account eligibility must be reviewed before accepting live international payments.


### PayPal hosted checkout
- Configure `PAYPAL_ENV`, `PAYPAL_CLIENT_ID`, `PAYPAL_CLIENT_SECRET`, `PAYPAL_WEBHOOK_ID`, `PAYPAL_SUCCESS_URL`, and `PAYPAL_CANCEL_URL`.
- `POST /api/business/organizations/:orgId/documents/:documentId/paypal-checkout` creates an Orders v2 checkout for the outstanding balance. The server captures an approved order only after verifying the signed `CHECKOUT.ORDER.APPROVED` webhook.
- Configure the PayPal webhook URL as `POST /api/business/payments/paypal/webhook`; subscribe to checkout order approval and payment capture completed/denied events. Amount and currency are checked against the stored invoice before it is reconciled.
- Begin with sandbox credentials. Confirm webhook delivery, account eligibility, supported currencies, refunds, disputes, and production credentials before accepting live payments.


## Public multi-business marketplace search

The public marketplace discovery API now provides filterable, paginated business and product/service search without authentication:

- `GET /api/marketplace?q=chair&category=furniture&country=KE&location=Nairobi&page=1&pageSize=20` searches published businesses.
- `GET /api/marketplace/products?q=chair&category=furniture&country=KE&location=Nairobi&page=1&pageSize=20` searches active catalogue items across public storefronts.
- Search terms are treated as literal text, pagination is bounded, and responses omit owner IDs, private workspace settings, customer records and payment details.
- `location` matches the business country and configured branch names/addresses; it is not a geocoding or distance-radius search.
- Both endpoints return `pagination` metadata and use short public cache headers. Only active catalogue items make a business discoverable.

These APIs provide the backend discovery surface. A polished public marketplace web interface, customer checkout without account creation, subscription billing and enforceable plan quotas remain separate acceptance items; the API endpoints alone do not mean those items are complete.


## SaaS plan quota enforcement

A shared plan-limit definition now covers member seats, customers, catalogue items, documents, enterprise records, branches and workflow definitions. The usage endpoint reports these resources and remaining allowance, and create endpoints reject writes beyond the current plan with HTTP 402 and `code: PLAN_LIMIT_REACHED`. This is quota enforcement only: it does **not** activate paid plans, charge cards, renew subscriptions or prove a subscription is current. Paid-plan changes and recurring billing still require a verified provider checkout/webhook lifecycle and a restricted billing-admin process.


Operational backup/restore instructions are in [Operations, Backup and Disaster Recovery](OPERATIONS_DISASTER_RECOVERY.md). The scripts are intentionally manual and non-production-safe by default; configure scheduling and off-site storage in the hosting environment.


## Customer financial statements

Authorized owners, admins, managers and finance team members can request a tenant-scoped customer statement with `GET /api/business/organizations/:orgId/customers/:customerId/statement`. Optional `from` and `to` ISO date filters narrow the statement period. The response lists invoices, receipts and orders, paid and outstanding balances, and totals grouped by currency; it never combines different currencies into one amount. Access is checked against both the organization and customer record, and the result is bounded to 500 documents.


The Flutter customer-facing **Stores** tab now consumes the paginated marketplace APIs. It supports switching between business discovery and product/service search, keyword/category filters, country and town/branch filters, opening the business storefront, and starting checkout through the existing authenticated checkout flow. The UI does not expose the Business administration workspace to customers during browsing.


## Subscription lifecycle API (billing integration boundary)

- `GET /api/business/subscription-plans` lists plans and indicates whether signed events are configured.
- `GET /api/business/organizations/:orgId/subscription` returns the current plan and lifecycle status to the workspace owner.
- `POST /api/business/organizations/:orgId/subscription/request` records an upgrade request only; it does not grant paid access.
- `POST /api/business/billing/webhook` processes signed, idempotent lifecycle events: `subscription.activated`, `subscription.past_due`, `subscription.canceled`, and `subscription.expired`.

Set `CHATIFY_BILLING_WEBHOOK_SECRET` to a long random secret and configure a trusted billing adapter to sign the exact JSON request bytes using HMAC-SHA256 in `x-chatify-billing-signature`. This is an integration boundary, not hosted checkout. A real Stripe/PayPal subscription checkout, native provider-signature verification, renewals, proration, retries, and end-to-end provider callbacks remain unverified until a provider adapter and live test credentials are configured.


## Support response targets and escalation

- `GET /api/business/organizations/:orgId/support/sla` reports tenant-scoped support cases, response targets and deadline/breach status. Workspace owners can configure response minutes under `settings.serviceTargets.responseMinutes` for `urgent`, `high`, `normal` and `low` priorities (5–43,200 minutes).
- `POST /api/business/support/sla/escalate` is intended for an external scheduler and requires `CHATIFY_SLA_CRON_SECRET` in the `x-chatify-sla-secret` header. It raises overdue cases from low/normal to high, and to urgent after twice the response target.

This job changes case priority and records an update; it does not send email/SMS/push alerts or provide guaranteed background scheduling. Configure and monitor a single external scheduler before treating escalation as operational.


## Customer portal and verified-purchase reviews

- `GET /api/customer/portal/orders` and `GET /api/customer/portal/requests` expose only orders created by the signed-in buyer and their own service requests.
- `POST /api/customer/portal/requests` creates cancellation, return, support or delivery-question requests; seller-side review is available under `/api/business/organizations/:orgId/portal/requests`. Approving a request does not itself issue a refund or change payment-provider state.
- `GET /api/storefront/:slug/reviews` exposes approved reviews only. A review submission requires a matching paid/fulfilled order created by that signed-in buyer; one review per order is enforced by a unique index. Owners/admins/managers moderate reviews through `/api/business/organizations/:orgId/reviews`.

These are authenticated API journeys; a polished customer-facing portal UI, provider-backed refund automation, and production database/index migration checks remain separate acceptance items.
