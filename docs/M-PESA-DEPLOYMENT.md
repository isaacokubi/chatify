# M-Pesa STK Push deployment checklist

Chatify defaults to `MPESA_ENV=mock` for safe demos. Mock mode intentionally does **not** send a Safaricom prompt. A real prompt requires a running Chatify API with approved Daraja credentials; a Vercel frontend deployment alone cannot enable payments.

## Required backend environment

Configure these values in the hosting provider for the **Node.js API service** (never commit real values):

- `NODE_ENV=production`
- `MPESA_ENV=production`
- `MPESA_CONSUMER_KEY` — production Daraja consumer key
- `MPESA_CONSUMER_SECRET` — production Daraja consumer secret
- `MPESA_SHORTCODE` — approved paybill/till shortcode
- `MPESA_PASSKEY` — matching production STK passkey
- `MPESA_TRANSACTION_TYPE=CustomerPayBillOnline` for a paybill, or `CustomerBuyGoodsOnline` for a supported till
- `MPESA_CALLBACK_TOKEN` — at least 32 random characters (`openssl rand -hex 32`); it must match the token in the callback URL path.
- `MPESA_CALLBACK_URL=https://YOUR-API-HOST/api/payments/daraja/callback/<same-token>` — publicly reachable HTTPS URL; the route rejects missing or incorrect tokens before reading payment state
- Startup validates that platform callback token and URL agree in sandbox and production modes.
- `SCHOOL_DARAJA_CALLBACK_TOKEN` — a distinct token of at least 32 random characters for school fee/donation callbacks
- `MONGODB_URI` — persistent MongoDB Atlas connection
- `JWT_SECRET` — at least 32 characters
- `CLIENT_ORIGIN` — exact HTTPS origin(s) of the deployed client

Use the Daraja **sandbox** credentials and `MPESA_ENV=sandbox` only on a non-production API environment. Production deliberately refuses sandbox mode.

## Other payment-flow settings

School fee/donation callbacks use `PUBLIC_API_URL` (or `API_URL`) and `SCHOOL_DARAJA_CALLBACK_TOKEN`; school-specific Daraja credentials are encrypted in the school payment profile and require `SCHOOL_PAYMENT_ENCRYPTION_KEY` in the API environment. Merchant POS/storefront STK uses `POS_STK_PUBLIC_BASE_URL`, `POS_STK_CALLBACK_TOKEN`, and `POS_DARAJA_ENCRYPTION_KEY`; each merchant's own authorized shortcode credentials are encrypted in its organization settings. POS C2B confirmation uses `POS_C2B_CALLBACK_TOKEN` and optional `POS_C2B_ALLOWED_IPS`.

This API implements the POS C2B confirmation receiver; it does not register C2B URLs with Safaricom. An operator must register the exact HTTPS validation/confirmation URLs in the authorized Daraja app/portal and perform its simulator or sandbox transaction. Safaricom's portal requires URL registration before C2B simulation ([Daraja testing guide](https://developer.safaricom.co.ke/apis/IotSimManagement)). Registration alone is not delivery evidence. Platform-fee collection is disabled/no-op, and the legacy callback is not a new charge capability. Real-provider business invoice STK is disabled because its existing platform provider would send proceeds to the platform shortcode.

## Verification record — 2026-10-26

The local ignored `server/.env` selected sandbox and contained platform Daraja settings; the matching HTTPS callback path/token passed code validation. The API at the recorded callback host returned HTTP 200 from `/api/health` with TLS verification success. A synthetic callback with an invalid token returned HTTP 404. These checks establish current public reachability and fail-closed route behavior, not the deployed secret value or acceptance of a valid Safaricom callback.

A real sandbox Dynamic QR request reached the Daraja endpoint but returned HTTP 401; no QR or payment was confirmed. The Daraja app's product authorization requires review in the provider portal. No approved sandbox phone was configured and no Android test device was attached, so no STK prompt or provider-delivered payment callback was tested in this run. The Render CLI's stored token is expired and no Daraja portal session is connected, so production settings/approval and C2B callback registration remain unchecked. See [M-Pesa test evidence](M-PESA_TESTING.md#verification-update-2026-10-26).

The API logs sanitized reconciliation stage/outcome fields and bounds the platform sweep to two payments per minute and five query attempts. No external payment alerting integration or deployed alert delivery was verifiable here. Operators must monitor application logs and provider statements for stale pending attempts until production alert routing is configured and exercised. Statement matching and manual review are operator procedures; automatic provider-statement import is not implemented.

## Safe verification

1. Confirm the API `/health` endpoint returns HTTP 200 and `database: connected`.
2. Verify the Daraja app is approved for STK Push and the shortcode, passkey and transaction type belong together.
3. Confirm the callback URL is public HTTPS, reachable from Safaricom, ends in the configured tokenized route, and points to the same API service. Redact callback paths from proxy/access logs.
4. Initiate a small test payment using a registered Kenyan mobile number and check API-host logs for the safe stage labels `oauth_transport`, `oauth_auth`, `stk_transport` or `stk_rejected`.
5. Treat an accepted STK request as **pending**, not paid. The participant or school administrator/staff may request a bounded status query. A successful status-query result lacking callback amount, payer phone and receipt data remains pending; use a verified callback or the school’s actual M-Pesa receipt/manual verification process to complete reconciliation. Retry limits and backoff are enforced by the API.

The app must never collect or transmit the user's M-Pesa PIN. The PIN is entered only in Safaricom's official prompt.
