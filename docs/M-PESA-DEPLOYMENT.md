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
- `MPESA_CALLBACK_URL=https://YOUR-API-HOST/api/payments/daraja/callback` — publicly reachable HTTPS URL
- `MONGODB_URI` — persistent MongoDB Atlas connection
- `JWT_SECRET` — at least 32 characters
- `CLIENT_ORIGIN` — exact HTTPS origin(s) of the deployed client

Use the Daraja **sandbox** credentials and `MPESA_ENV=sandbox` only on a non-production API environment. Production deliberately refuses sandbox mode.

## Safe verification

1. Confirm the API `/health` endpoint returns HTTP 200 and `database: connected`.
2. Verify the Daraja app is approved for STK Push and the shortcode, passkey and transaction type belong together.
3. Confirm the callback URL is public HTTPS, reachable from Safaricom, and points to the same API service.
4. Initiate a small test payment using a registered Kenyan mobile number and check API-host logs for the safe stage labels `oauth_transport`, `oauth_auth`, `stk_transport` or `stk_rejected`.
5. Treat an accepted STK request as **pending**, not paid. Only the verified Daraja callback confirms success. Do not repeatedly tap Pay while an earlier request may still be active.

The app must never collect or transmit the user's M-Pesa PIN. The PIN is entered only in Safaricom's official prompt.
