# M-Pesa STK Push deployment checklist

Chatify defaults to `MPESA_ENV=mock` for safe demos. Mock mode intentionally does **not** send a Safaricom prompt. A real prompt requires a running Chatify API with approved Daraja credentials; a Vercel frontend deployment alone cannot enable payments.

## Required backend environment

Configure these values in the hosting provider for the **Node.js API service** (never commit real values):

- `NODE_ENV=production` (application runtime; retains production JWT/database/CORS checks)
- `MPESA_ENV=production` (Daraja provider; fixed live API host)
- `MPESA_PRODUCTION_CONSUMER_KEY`, `MPESA_PRODUCTION_CONSUMER_SECRET`, `MPESA_PRODUCTION_SHORTCODE`, `MPESA_PRODUCTION_PASSKEY` — production-only Daraja credentials, shortcode and matching passkey. Production refuses generic or sandbox-scoped credentials.
- `MPESA_TRANSACTION_TYPE=CustomerPayBillOnline` for a paybill, or `CustomerBuyGoodsOnline` for a supported till
- `MPESA_CALLBACK_TOKEN` — at least 32 random characters (`openssl rand -hex 32`); it must match the token in the callback URL path.
- `MPESA_CALLBACK_URL=https://YOUR-API-HOST/api/payments/daraja/callback/<same-token>` — publicly reachable HTTPS URL; the route rejects missing or incorrect tokens before reading payment state
- Startup validates that platform callback token and URL agree in sandbox and production modes.
- `SCHOOL_DARAJA_CALLBACK_TOKEN` — a distinct token of at least 32 random characters for school fee/donation callbacks
- `MONGODB_URI` — persistent MongoDB Atlas connection
- `JWT_SECRET` — at least 32 characters
- `CLIENT_ORIGIN` — exact HTTPS origin(s) of the deployed client

`NODE_ENV` and `MPESA_ENV` are separate settings. Production runtime requires explicit `MPESA_ENV`; it never defaults to mock or sandbox. In development/test, generic `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE` and `MPESA_PASSKEY` are used with the selected provider mode. Production selects only the matching scoped set: `MPESA_PRODUCTION_*` for live or `MPESA_SANDBOX_*` for sandbox. Generic or opposite-mode credentials cannot satisfy production startup. `MPESA_ENV=sandbox` always uses `https://sandbox.safaricom.co.ke`; `MPESA_ENV=production` always uses `https://api.safaricom.co.ke`. Sandbox on a production runtime is disabled unless `MPESA_ALLOW_SANDBOX_IN_PRODUCTION=true` is set literally. It defaults to false and accepts only `true` or `false`; the opt-in does not switch endpoints or credentials. Use this only for a deliberately isolated sandbox service after verifying its database, account, callback and access controls. Do not set the Render service's `NODE_ENV=production` until the complete production runtime configuration is ready.

## Other payment-flow settings

School fee/donation callbacks use `PUBLIC_API_URL` (or `API_URL`) and `SCHOOL_DARAJA_CALLBACK_TOKEN`; school-specific Daraja credentials are encrypted in the school payment profile and require `SCHOOL_PAYMENT_ENCRYPTION_KEY` in the API environment. Merchant POS/storefront STK uses `POS_STK_PUBLIC_BASE_URL`, `POS_STK_CALLBACK_TOKEN`, and `POS_DARAJA_ENCRYPTION_KEY`; each merchant's own authorized shortcode credentials are encrypted in its organization settings. POS C2B confirmation uses `POS_C2B_CALLBACK_TOKEN` and optional `POS_C2B_ALLOWED_IPS`.

This API implements the POS C2B confirmation receiver; it does not register C2B URLs with Safaricom. An operator must register the exact HTTPS validation/confirmation URLs in the authorized Daraja app/portal and perform its simulator or sandbox transaction. Safaricom's portal requires URL registration before C2B simulation ([Daraja testing guide](https://developer.safaricom.co.ke/apis/IotSimManagement)). Registration alone is not delivery evidence. Platform-fee collection is disabled/no-op, and the legacy callback is not a new charge capability. Real-provider business invoice STK is disabled because its existing platform provider would send proceeds to the platform shortcode.

## Verification record — 2026-10-26

### Hosted configuration follow-up — 2026-10-26

The Render CLI session is now authorized. The service was selected from the CLI service listing (`chatify-api`, this repository, `main`, root `server/`). The earlier service lookup 404 came from duplicating the `/v1` prefix in the API URL; the corrected endpoint returned HTTP 200. Hosted values were inspected without printing secrets. The service reports `MPESA_ENV=sandbox` and `NODE_ENV=development`; platform credential/shortcode/passkey/token/URL settings are present, and the HTTPS callback host and tokenized route match structurally. No conflicting service/environment-group values were found. This does not prove a valid Safaricom callback can authenticate or arrive. Health returned HTTP 200; a deliberately invalid-token callback returned 404. No valid callback or provider delivery was tested.

The test database name/host were matched between local and hosted configuration and the user confirmed it is the test database. Brian's ordinary account login and protected payment reads succeeded; no destructive test used this database. Hosted school, POS, and C2B callback configuration is incomplete (the relevant callback token/base/encryption settings are absent). Daraja portal access is still required to verify simulator eligibility and Dynamic QR product entitlement. No STK request was made, no phone prompt was sent, and no new callback/receipt/payment was generated. Production remains unverified. See [the detailed test report](M-PESA_TESTING.md#latest-continuation--2026-10-26-brian-and-hosted-configuration).

The local ignored `server/.env` selected sandbox and contained platform Daraja settings; the matching HTTPS callback path/token passed code validation. On the latest check, the API at the recorded callback host returned HTTP 200 from `/api/health` with TLS verification success and DNS resolution. A synthetic callback with an invalid token returned HTTP 404. These checks establish public reachability and fail-closed route behavior, not the deployed secret value or acceptance of a valid Safaricom callback.

A real sandbox Dynamic QR request reached the Daraja endpoint but returned HTTP 401, classified as a product-entitlement/authorization rejection; no QR or payment was confirmed. The Daraja app's product authorization requires review in the provider portal. An approved primary test number and conditional fallback were supplied for this task, but neither was used because authenticated simulator access was unavailable to verify the primary's eligibility; primary ineligibility was not established, so fallback use was not justified. No STK prompt or provider-delivered payment callback was tested. The Render CLI's stored token is expired and no Daraja portal session is connected, so hosted settings/approval and C2B callback registration remain unchecked. See [M-Pesa test evidence](M-PESA_TESTING.md#latest-continuation-2026-10-26).

The API root health check is not a payment acceptance test. Do not initiate a provider STK directly from a credential-bearing local shell: first restore authorized hosting access and a Chatify authenticated test session so the attempt is durably associated with a payment and its callback can be verified. Use the approved sandbox number order in the testing guide; do not send a prompt if a prior initiation outcome is uncertain.

The later 2026-10-26 acceptance-gate rerun reconfirmed local sandbox configuration and public health/TLS, but `render services --output json` still failed with an expired CLI token. No valid hosted callback authentication, Daraja number eligibility, STK request, or phone prompt was verified. An authorized operator must run `render login`, inspect the correct sandbox service configuration with values masked, and check simulator test-number support in Daraja before requesting any prompt. The local settings must not be treated as proof of production or hosted settings.

The subsequent Brian demo-account test pass repeated public health/TLS and invalid-token callback checks, but did not attempt account login or STK: the prompt did not include the demo-account password, and the Daraja simulator was unavailable to confirm number eligibility. `render login` later completed, and the CLI identified the Chatify API service on `main` with root directory `server/`; the CLI does not expose environment-variable settings. Use its authenticated Dashboard Environment page to verify isolated sandbox settings and callback token/path match without displaying values. Do not connect to an unverified production database to check the account. Authenticate using an approved secure password input and use only the normal chat user's authorized platform flow. School and merchant flows require their own authorized tenant accounts/configuration.

The API logs sanitized reconciliation stage/outcome fields and bounds the platform sweep to two payments per minute and five query attempts. No external payment alerting integration or deployed alert delivery was verifiable here. Operators must monitor application logs and provider statements for stale pending attempts until production alert routing is configured and exercised. Statement matching and manual review are operator procedures; automatic provider-statement import is not implemented.

### Callback settlement safeguards

New platform, school and merchant STK attempts persist provider name, shortcode and endpoint. Callbacks are bounded to 64 KiB, rate-limited, matched by the stored request IDs and checked against the original provider mode/configuration. Before a callback changes financial state, Chatify queries the same Daraja provider for the exact CheckoutRequestID and requires result code/state agreement. Query success alone lacks receipt and payer metadata and does not issue a receipt. The callback route token is a high-entropy routing secret; it is not a cryptographic signature from Safaricom. The implementation uses the provider query, correlation, amount/phone/receipt checks and idempotent compare-and-set transitions as additional controls. Safaricom describes STK as an asynchronous flow with a callback, sandbox test app and separate go-live workflow ([M-Pesa Express Simulate](https://developer.safaricom.co.ke/apis/MpesaExpressSimulate)).

Previously exposed Daraja consumer key/secret, STK passkey and callback token must be rotated. Use the Daraja portal to issue/revoke the application credentials and update the matching Render environment values. Update the callback token and URL together through Render Dashboard after pending checkouts have been reconciled; the last read-only inspection found unresolved pending Daraja attempts. Verify presence/structure with values masked, then verify deployment and callback behavior. No rotation or live setting change was performed during the incident investigation.

## Safe verification

1. Confirm the API `/health` endpoint returns HTTP 200 and `database: connected`.
2. Verify the Daraja app is approved for STK Push and the shortcode, passkey and transaction type belong together.
3. Confirm the callback URL is public HTTPS, reachable from Safaricom, ends in the configured tokenized route, and points to the same API service. Redact callback paths from proxy/access logs.
4. Initiate a small test payment using a registered Kenyan mobile number and check API-host logs for the safe stage labels `oauth_transport`, `oauth_auth`, `stk_transport` or `stk_rejected`.
5. Treat an accepted STK request as **pending**, not paid. The participant or school administrator/staff may request a bounded status query. A successful status-query result lacking callback amount, payer phone and receipt data remains pending; use a verified callback or the school’s actual M-Pesa receipt/manual verification process to complete reconciliation. Retry limits and backoff are enforced by the API.

The app must never collect or transmit the user's M-Pesa PIN. The PIN is entered only in Safaricom's official prompt.
