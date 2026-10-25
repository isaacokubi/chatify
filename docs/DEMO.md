# Chatify Defense Demo

## Repeatable demo seed

The API seed creates Chatify demo accounts, direct and group conversations, contacts and a Memory Card; two Business organizations with three branches; seven catalogue items, three customers, an order, invoice and quote, tasks, a support case, supplier, disabled workflow preview, shared-inbox assignment and sourcing request; and a school with administrator/staff/parent memberships, six linked students, six attendance records, twelve assessments, role-visible school messages, parent and staff conferences and one **pending verification** fee example. The current application has no separate cart/order model, teacher login role, school class/subject/term entities, or simulated payment ledger; the seed uses the existing class, subject and term text fields and does not invent unsupported records. Its sample order is a Business `order` document. Business invoice/order values are unpaid, the school fee remains pending, and no payment was initiated or received.

Use a dedicated development database whose database name contains `demo`, `dev`, `development` or `test`. The script refuses `NODE_ENV` other than `development`, an unset confirmation, and any database with a production name. For a verified connected development database whose name is simply `chatify`, set `CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE=YES` as a separate explicit acknowledgement. It never drops collections. Existing accounts are changed only when their `demoSeedKey` identifies this seeder; an unmarked account that collides with a demo email stops the run before any writes.

Set `NODE_ENV=development`, `CHATIFY_SEED_DEMO=YES`, `MONGODB_URI` and `SEED_DEMO_PASSWORD` in a private local environment. `DEMO_SEED_PASSWORD` remains a legacy alias. The password must be 12–72 UTF-8 bytes. For a shared classroom demo, configure the requested common password locally; do not put it in `.env.example`, source code, shell history, Git, or reports. These shared demo credentials are only for testing and must never be used for production users.

From `server/`, preview the seed without connecting to MongoDB or making writes:

```sh
npm run seed -- --dry-run
```

After confirming the selected database is disposable and correctly named, seed it with:

```sh
npm run seed
```

To also verify all eight accounts through the real HTTP login handler, start the API locally and rerun the seed with `CHATIFY_SEED_VERIFY_LOGIN=YES`. It sends credentials only to a localhost URL (default `http://127.0.0.1:5000`); use `CHATIFY_DEMO_API_URL` only for another local port. It records pass/fail in the account register and never logs tokens or passwords.

The seed uses stable IDs and upserts, so a rerun reconciles only its own records. It hashes passwords with bcrypt and checks that each saved hash accepts the configured password. This does not exercise the HTTP login endpoint. `DEMO_ACCOUNT_REGISTER.md` is regenerated after a completed run; it contains no passwords or hashes. To remove only demo records, back up the dedicated database, then drop that **entire dedicated demo database** with your MongoDB administration tool. There is no automatic reset command.

The seeder blocks production-named databases and requires development mode, but the operator must still verify the private MongoDB URI points to the intended isolated demo database before execution. Do not use production credentials or production data.

Seed coverage follows actual models: platform roles are `admin`/`user`; school roles are workspace memberships (`admin`, `staff`, `parent`); Business roles are organization memberships. User accounts are not created for school pupils because the current schema stores pupils as school student records.

Register Alice and Brian. Alice searches for Brian, starts a direct chat and sends: `Let's meet at the library tomorrow at 2 PM to discuss the project.` Use the Memory action to save the extracted event as `Project Meeting`, then open Memories. Send another message and choose `Delete after reading`; trigger the read flow and show the expired message is removed/hidden. Create a group, add a member, send a message and demonstrate administrator controls.

Password-reset delivery, Cloudinary uploads and push delivery require real provider configuration. Development image storage and notifications use mocks. Never use production users or real provider secrets for a demo. Push notifications require native Firebase configuration; when it is available, Flutter requests permission and registers its token through the authenticated `/api/devices` endpoint.

Explain the innovations simply: Memory Cards turn useful conversational information into structured records; expiration gives a message a configurable application-level lifecycle.

## Chatify Pay

Local demo mode requires no Daraja account or credentials. Leave `MPESA_ENV=mock` in `server/.env`. In a direct chat, tap the payments action, enter amount, the payer's Safaricom number and a short description, then ask the other participant to tap **Pay with M-Pesa**. The client says the payment is a local demo. To demonstrate outcomes without a real network call, the payer can use `POST /api/payments/:paymentId/mock-result` with one of `SUCCESS`, `FAILED` or `CANCELLED` using their bearer token (for example through an API client). The payment card/history displays that result. This is not a Safaricom transaction.

### Daraja sandbox setup

1. Create/sign in to a developer account at [Safaricom Daraja](https://developer.safaricom.co.ke/), create a sandbox app and enable the M-Pesa Express/STK Push product. Copy that app's Consumer Key and Consumer Secret from its details. Safaricom documents token creation in its [Authorization API guide](https://developer.safaricom.co.ke/apis/Authorization) and walks through sandbox credentials in its [official FAQs](https://developer.safaricom.co.ke/faqs).
2. In the portal's sandbox test credentials, obtain the Lipa na M-Pesa Online shortcode and passkey for the app. Do not copy credential values into Git, chat, or logs.
3. Start Chatify's backend on a public HTTPS host. For local testing, expose the server using a temporary HTTPS tunnel (such as ngrok), generate `MPESA_CALLBACK_TOKEN` with `openssl rand -hex 32`, and set `MPESA_CALLBACK_URL` to the public tunnel URL plus `/api/payments/daraja/callback/<same-token>`. A localhost URL, emulator address, or private LAN address cannot receive Safaricom callbacks. Keep the tunnel running for the complete STK flow and redact the tokenized URL from logs.
4. Set `MPESA_ENV=sandbox`, `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE`, `MPESA_PASSKEY`, `MPESA_CALLBACK_TOKEN`, `MPESA_CALLBACK_URL`, and `MPESA_TRANSACTION_TYPE=CustomerPayBillOnline` in the private `server/.env` file. Restart the server. Use a supported Safaricom test number and sandbox values as specified in the portal.
5. Create a payment request in a conversation, then have the payer initiate it. The phone receives the STK prompt; the user enters their PIN only in that Safaricom prompt. The API returns pending after acceptance and changes status only after a matching callback. Confirm the callback reaches the public HTTPS endpoint and appears on both connected clients.

For deployment, use a stable HTTPS backend URL and configure the tokenized callback path exactly in `MPESA_CALLBACK_URL`. Production requires `NODE_ENV=production`, explicit `MPESA_ENV=production`, approved production Daraja credentials and the callback token. Do not point a production app at sandbox or enable production merely for a demo.


## Production M-Pesa STK Push

For the required backend environment, real-prompt prerequisites, and safe verification checklist, see [M-PESA-DEPLOYMENT.md](M-PESA-DEPLOYMENT.md). Mock mode is a simulation and never sends a Safaricom prompt.
