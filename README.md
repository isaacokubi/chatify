# Chatify — Chat. Remember. Let Go.

Chatify is a final-year-project mobile communication system built around real-time **Chat**, structured conversational **Memory**, and configurable message **Expiration**.

## Platform administrator

Chatify has a role-protected platform administrator dashboard for operational metrics,
user account status management, and payment monitoring. The dashboard is visible only
when the authenticated API response reports `role: "admin"`; the API independently
checks the database role on every administrative request.

To provision the first administrator safely:

1. Set `MONGODB_URI`, `ADMIN_NAME`, `ADMIN_EMAIL`, and a unique `ADMIN_PASSWORD`
   (12–72 UTF-8 bytes) in the private environment used for the server.
2. From `server/`, run `npm run seed:admin` once against the intended database.
3. Sign in using those configured credentials and open the **Admin** tab.
4. Store the password in a password manager and rotate it after provisioning if required.
   Never commit real credentials or put the administrator password in mobile app source.

The seed command creates or promotes only the account matching `ADMIN_EMAIL`, marks
its email verified, and does not use a hard-coded default administrator password. Re-running
the command resets that account's password to the currently configured secret.

The dashboard's successful payment total is gross recorded transaction volume, not profit.
It does not represent reconciled settlements, refunds, provider fees, or tax accounting.

## Repository
- mobile/ — Flutter/Dart client
- server/ — Node.js/Express/Socket.IO API
- docs/ — architecture, API, database, development, security and demo notes
- [Latest verification record (2026-10-22)](docs/VERIFICATION_2026-10-22_BILLING_BOUNDARY.md) — **all automated CI checks passed** on commit `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`: 193 backend tests passed (0 failed), dependency audit and backend lint/syntax checks passed, Flutter analysis/tests passed, Flutter web build passed, and Android debug APK build passed. [Quality workflow](https://github.com/isaacokubi/chatify/actions/runs/39739597328) · [Full CI workflow](https://github.com/isaacokubi/chatify/actions/runs/39739597321). Live Daraja sandbox and deployed-production acceptance checks remain separate release gates.
- [Demo setup and account register](docs/DEMO.md) — safe repeatable seed instructions, current sample data coverage and demo credentials configuration.
- [Project walkthrough](docs/PROJECT_WALKTHROUGH.md) — plain-language guide to how the system works, how the main features connect, security concepts, code navigation, and tutor-defense preparation.
- [Code walkthrough](docs/CODE_WALKTHROUGH.md) — code-reading guide with focused flow explanations.
- [Business platform guide](docs/BUSINESS_PLATFORM.md) — organization workspaces, CRM, catalogues, quotations, payment reconciliation, tasks, shared inbox handover, suppliers, workflows, audit logs and storefront APIs.
- [Commercial readiness acceptance matrix](docs/COMMERCIAL_READINESS.md) — evidence-based status of commercial modules, acceptance gates, and known production blockers.
- [Remediation log (2026-10-22)](docs/REMEDIATION_2026-10-22.md) — commission-free billing policy, payment callback safeguards, and remaining production acceptance gates.
- [Billing boundary verification record (2026-10-22)](docs/VERIFICATION_2026-10-22_BILLING_BOUNDARY.md) — regression test scope and the CI evidence required before claiming it passed.

## Core innovations
- **Remember:** deterministic local extraction identifies event, task, payment, place and note candidates that users can save as Memory Cards.
- **Let Go:** messages support NONE, AFTER_READ, AFTER_TIME and AFTER_REPLY application-level lifecycles.
- **Private text:** new text messages use client-side X25519/HKDF/AES-GCM encryption; see [the E2EE design and limitations](docs/E2EE.md).

## Backend
~~~bash
cd server
cp .env.example .env
npm install
npm test
npm run lint
npm start
~~~
Set MONGODB_URI to MongoDB Atlas and JWT_SECRET to a long random value.

## Mobile
~~~bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk
~~~
The sample Android-emulator API address is http://10.0.2.2:5000. Set a different API address at build/run time with --dart-define=CHATIFY_API=https://your-api.example; a physical device must use a reachable development LAN address.

## Demo
Register Alice and Brian. From Contacts search for the other account and start a direct conversation. Send: “Let's meet at the library tomorrow at 2 PM to discuss the project.” Use the sparkle action to extract and save the candidate, then open Memories. Send another message and choose Delete after reading, Delete after 1 hour, or Delete after reply.

### Chatify Pay demo

With the default MPESA_ENV=mock, request an amount from the other conversation member and tap **Pay with M-Pesa**. The UI labels the request **Local demo**; no Safaricom transaction is made and the app never collects an M-Pesa PIN. To use Daraja sandbox, follow [docs/DEMO.md](docs/DEMO.md). Never select production mode for a classroom demo.

Payment requests move from PENDING to SUCCESS, FAILED, or CANCELLED. A real request stays pending until Daraja's callback confirms its result; an accepted STK request is not proof that money was received.

## Merchant POS STK Push (Till and Paybill)

POS STK Push is initiated with **each merchant's own Daraja app credentials, passkey, and shortcode**. A merchant must have Safaricom/Daraja authorization for that exact Till or Paybill; entering a public payment number alone cannot authorize STK Push. The server rejects credentials whose shortcode differs from the merchant's configured POS destination and never falls back to Chatify's platform shortcode.

Configure these private server environment variables before enabling merchant STK:
- `POS_DARAJA_ENCRYPTION_KEY`: a persistent 32-byte encryption key encoded as 64 hex characters. Generate once with `openssl rand -hex 32`; store it in the hosting provider's secret manager and back it up securely. Rotating it requires a deliberate credential re-encryption plan.
- `POS_STK_CALLBACK_TOKEN`: at least 32 random characters, generated with `openssl rand -hex 32`.
- `POS_STK_PUBLIC_BASE_URL`: the public HTTPS origin of this API, for example `https://your-api.example`.

A business owner/authorized manager configures its payment profile through `PUT /api/business/organizations/:orgId/pos/payment-profile`, supplying `method`, the matching `tillNumber` or `paybillNumber`, and the merchant Daraja `mode` (`sandbox` or `production`), `shortcode`, `consumerKey`, `consumerSecret`, and `passkey`. The API stores these credentials encrypted with AES-256-GCM and never returns the secrets. Do not send real production secrets from a public storefront or commit them to source control.

Create a POS charge, then call `POST /api/business/organizations/:orgId/pos/charges/:paymentId/stk` with the customer's Kenyan `phone`. The charge stays pending until the server receives the token-protected callback at `/api/business/pos/stk/callback/:token` and validates the exact checkout/merchant request IDs, amount, payer phone and unique M-Pesa receipt. A screenshot or successful STK initiation is not proof of payment. Test with Safaricom sandbox credentials first.

## Production providers
MongoDB Atlas is supported directly through configuration. SMTP password-reset email, Cloudinary image storage, Firebase Admin/FCM message notifications, and Daraja STK Push use production adapters behind small provider boundaries. Set their environment variables before enabling those features. Development storage, email, notification and payment providers remain mocks; the development email mock never prints reset tokens, and mock payments are labeled and never contact Safaricom. The Flutter app registers its FCM token with the authenticated /api/devices endpoint when Firebase is configured, retries on token refresh, unregisters the active token on logout, and opens authorized conversations from notification taps. Add the platform-specific Firebase configuration before expecting device notifications; Firebase initialization failures are non-fatal so development chat remains usable without credentials.

Set a persistent JWT_SECRET in the local environment if demo sessions must survive server restarts; production refuses to start without a 32-character secret. Production CORS requires exact HTTPS Flutter Web origins in CLIENT_ORIGIN; the Flutter Web host is not currently specified in this repository.

## School communication and fee payments

School administrators can configure a school-specific Daraja Paybill or Till, staff and parent membership, fee payments, conferences and official fee receipts. M-Pesa payments use that school's own shortcode and passkey; a pending STK request is not treated as paid. The API confirms a payment only after a Daraja callback matches the stored CheckoutRequestID and MerchantRequestID, the expected amount and payer phone, and a valid M-Pesa receipt number. Duplicate callbacks are idempotent. The generated receipt HTML is stored with the fee record in MongoDB and attached to emails sent to the parent and active school administrators.

Before enabling this in the API deployment, configure these private environment variables:

- `PUBLIC_API_URL`: the public HTTPS base URL of this API, used to construct `/api/schools/daraja/callback`.
- `SCHOOL_PAYMENT_ENCRYPTION_KEY`: a unique random secret of at least 32 characters. School-specific Daraja consumer keys, consumer secrets and passkeys are encrypted at rest with AES-256-GCM. Keep this key backed up securely; do not commit it or send it in chat.
- `SMTP_URL` and `SMTP_FROM`: required for receipt email delivery. If SMTP is unavailable, the receipt remains stored and downloadable, and an administrator can retry delivery using `POST /api/schools/:schoolId/fees/:paymentReference/receipt/resend`.

A school administrator must enter that school's Daraja consumer key, consumer secret, passkey and matching Paybill/Till. Live deployments reject sandbox credentials. Keep all real credentials in the private API environment or the authenticated school setup form over HTTPS, never in source control. Bank transfer remains a manual-verification workflow; it does not trigger an M-Pesa prompt.

## Security
Passwords are bcrypt-hashed. JWTs protect REST and Socket.IO. Server-side membership/admin checks protect conversations and groups. Helmet, CORS and rate limiting are enabled. Secrets are excluded by Git ignore rules. New text-message bodies are encrypted on the client, but legacy messages, attachments, Memory Cards, multi-device recovery and forward secrecy are not yet covered; do not claim the whole system is fully end-to-end encrypted. Message expiration is application-level removal/hiding and is not cryptographic secure deletion. See [docs/E2EE.md](docs/E2EE.md) for the threat model and production gates.

See docs/ for the defense-oriented architecture, API, database, development, security and demo notes.
