# Chatify Defense Demo

Register Alice and Brian. Alice searches for Brian, starts a direct chat and sends: `Let's meet at the library tomorrow at 2 PM to discuss the project.` Use the Memory action to save the extracted event as `Project Meeting`, then open Memories. Send another message and choose `Delete after reading`; trigger the read flow and show the expired message is removed/hidden. Create a group, add a member, send a message and demonstrate administrator controls.

Password-reset delivery, Cloudinary uploads and push delivery require real provider configuration. Development image storage and notifications use mocks. Never use production users or real provider secrets for a demo. Push notifications require native Firebase configuration; when it is available, Flutter requests permission and registers its token through the authenticated `/api/devices` endpoint.

Explain the innovations simply: Memory Cards turn useful conversational information into structured records; expiration gives a message a configurable application-level lifecycle.

## Chatify Pay

Local demo mode requires no Daraja account or credentials. Leave `MPESA_ENV=mock` in `server/.env`. In a direct chat, tap the payments action, enter amount, the payer's Safaricom number and a short description, then ask the other participant to tap **Pay with M-Pesa**. The client says the payment is a local demo. To demonstrate outcomes without a real network call, the payer can use `POST /api/payments/:paymentId/mock-result` with one of `SUCCESS`, `FAILED` or `CANCELLED` using their bearer token (for example through an API client). The payment card/history displays that result. This is not a Safaricom transaction.

### Daraja sandbox setup

1. Create/sign in to a developer account at [Safaricom Daraja](https://developer.safaricom.co.ke/), create a sandbox app and enable the M-Pesa Express/STK Push product. Copy that app's Consumer Key and Consumer Secret from its details. Safaricom documents token creation in its [Authorization API guide](https://developer.safaricom.co.ke/apis/Authorization) and walks through sandbox credentials in its [official FAQs](https://developer.safaricom.co.ke/faqs).
2. In the portal's sandbox test credentials, obtain the Lipa na M-Pesa Online shortcode and passkey for the app. Do not copy credential values into Git, chat, or logs.
3. Start Chatify's backend on a public HTTPS host. For local testing, expose the server using a temporary HTTPS tunnel (such as ngrok) and set `MPESA_CALLBACK_URL` to the public tunnel URL plus `/api/payments/daraja/callback`. A localhost URL, emulator address, or private LAN address cannot receive Safaricom callbacks. Keep the tunnel running for the complete STK flow.
4. Set `MPESA_ENV=sandbox`, `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE`, `MPESA_PASSKEY`, `MPESA_CALLBACK_URL`, and `MPESA_TRANSACTION_TYPE=CustomerPayBillOnline` in the private `server/.env` file. Restart the server. Use a supported Safaricom test number and sandbox values as specified in the portal.
5. Create a payment request in a conversation, then have the payer initiate it. The phone receives the STK prompt; the user enters their PIN only in that Safaricom prompt. The API returns pending after acceptance and changes status only after a matching callback. Confirm the callback reaches the public HTTPS endpoint and appears on both connected clients.

For deployment, use a stable HTTPS backend URL and configure that exact callback path in `MPESA_CALLBACK_URL`. Production requires `NODE_ENV=production` and explicit `MPESA_ENV=production` plus approved production Daraja credentials. Production mode refuses to start when credentials or callback URL are missing. Do not point a production app at sandbox or enable production merely for a demo.


## Production M-Pesa STK Push

For the required backend environment, real-prompt prerequisites, and safe verification checklist, see [M-PESA-DEPLOYMENT.md](M-PESA-DEPLOYMENT.md). Mock mode is a simulation and never sends a Safaricom prompt.
