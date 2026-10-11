# Chatify Code Walkthrough (Tutor / Project Defense Guide)

This guide explains the code in plain language. Inline comments in the Flutter and API entrypoints give context next to important sections. It describes the current architecture; it is not a claim that every line is commented.

## 1. What the system does

Chatify is a mobile communication app with:
- **Chat:** direct and group conversations, text and media messages, replies, reactions, delivery/read state and real-time updates.
- **Remember:** turns a message into a structured Memory Card such as an event, task, payment, place or note.
- **Let Go:** supports message expiry modes (none, after reading, after a time, or after a reply). This is application-level hiding/removal, not cryptographic secure deletion.
- **Chatify Pay:** creates payment requests and can use a local mock provider or Safaricom Daraja integration. A successful STK initiation is not proof that money was received; a real result must be confirmed by the callback.
- **Accounts and privacy:** registration/login, JWT sessions, profile settings, blocked users, password reset, device tokens and notification preferences.

## 2. How the pieces fit together

```text
Flutter screens (mobile/lib/main.dart)
        | HTTPS/JSON requests
        v
Express API (server/src/index.js) ---- MongoDB / Mongoose
        |                                    stores users, chats, messages,
        |                                    memories, password resets, payments
        +---- Socket.IO events ----> connected conversation members
        +---- provider adapters ---> email, media storage, push notifications, M-Pesa
```

The mobile app is the interface. The server is the authority for identity, access permissions, validation and payment state. MongoDB stores durable records. Socket.IO pushes updates so other participants do not have to reload manually. Provider modules isolate third-party services from the main route handlers.

## 3. Important files

| File | Purpose |
|---|---|
| `mobile/lib/main.dart` | Flutter app entrypoint, HTTP client, shared client state, and the major screens (welcome, authentication, home, chat, memories, payments and profile). |
| `mobile/pubspec.yaml` | Flutter package dependencies and app metadata. `file_saver` supports saving downloaded image data to a device. |
| `server/src/index.js` | Express and Socket.IO entrypoint, middleware, database schemas, REST routes, payment callbacks, message expiry and shutdown. |
| `server/src/auth.js` | Shared bearer-token authentication logic used by protected API routes. |
| `server/src/payments.js` | Payment-provider selection, phone/amount validation, payment status rules and callback-result interpretation. |
| `server/src/seed.js` and `server/src/seedConfig.js` | Development/demo data setup and its configuration. Use only as intended by the project documentation. |
| `docs/API.md` | Endpoint reference: what each API route accepts and returns. |
| `docs/DATABASE.md` | Summary of persisted entities and their relationships. |
| `docs/ARCHITECTURE.md` | High-level architecture and component boundaries. |
| `docs/SECURITY.md` (if present) | Security assumptions and defensive design notes. Check the repository before citing a specific section. |
| `docs/DEMO.md` | Suggested demonstration flow, including safe local payment-demo guidance. |

Some integrations are implemented in separate provider/helper files. Read their configuration from `server/.env.example` and the provider-specific documentation rather than hard-coding credentials.

## 4. Main user flows

### A. Sign in and make an authenticated request
1. The user enters credentials in the Flutter authentication screen.
2. The app sends the credentials to the API.
3. The server validates the input and checks the stored password hash.
4. The server issues a signed JWT and returns a safe user profile (not the password hash).
5. The app keeps the session token and sends it with protected API calls.
6. The authentication middleware verifies the token and loads the user before a protected route continues.

**Defense point:** the app does not decide who a user is. The backend verifies the token and checks access on each protected operation.

### B. Send a chat message
1. The app loads conversations that belong to the signed-in user.
2. When opening a conversation, the server checks that the user is a member.
3. The app posts the message content/type and optional reply/expiry settings.
4. The server validates the message and membership, saves it to MongoDB and updates the conversation summary.
5. Socket.IO emits the new message to that conversation's room.
6. The client updates the screen when it receives the event; notification delivery is handled separately when configured.

### C. Save a Memory Card
1. The app sends message text to the memory-extraction endpoint.
2. The server returns candidate structured items; these are suggestions, not automatically saved facts.
3. The user chooses what to keep.
4. The app submits the chosen title, type and description.
5. The server validates ownership and any linked conversation/source message, then saves the memory.
6. The Memories screen lists records owned by the current user.

### D. Message expiry
1. The sender chooses an expiry mode.
2. The server stores the expiry policy and, for timed messages, the due time.
3. Reading, replying or the periodic cleanup job triggers expiry according to the selected mode.
4. The server clears/hides message content and emits an expiry event so open clients can update.

**Important limitation:** application-level expiry cannot guarantee that recipients did not take screenshots, copy content, or save it outside the app.

### E. M-Pesa / payment request
1. The requester creates a payment request with a payer, amount, phone and description.
2. The server validates the participants and allowed amount, then stores the request as pending.
3. The payer initiates the request. In mock mode, the app clearly labels the result as a local demo and does not contact Safaricom.
4. In Daraja mode, the provider sends an STK Push request and the server stores the returned request references.
5. Daraja sends a callback to the backend. The backend matches callback IDs to the original request and processes it once.
6. The payment status changes only after the appropriate provider result is verified.

**Defense point:** “request accepted” or “STK prompt sent” is not the same as “payment completed.” Never use production payment credentials for a classroom demo.

## 5. Security concepts to explain

- **Password hashing:** passwords are stored as bcrypt hashes rather than readable text.
- **JWT:** a signed token proves the session identity; protected routes still check resource access.
- **Membership/ownership checks:** users can only read or modify conversations, messages, memories and payment requests they are allowed to access.
- **Input validation:** the backend checks IDs, field types, text lengths, phone numbers, amounts and supported status values.
- **Rate limiting and Helmet:** reduce some common web/API abuse and add defensive HTTP headers.
- **Environment variables:** secrets and deployment-specific URLs belong in environment configuration, not source code.
- **Provider boundaries:** email, storage, notifications and payment integrations can use configured adapters; a mock provider is not a real external transaction.
- **CORS is not authentication:** CORS controls which browser origins can read responses; it does not replace server-side authentication/authorization.

## 6. How to demonstrate it to a tutor

1. Register two test accounts (for example Alice and Brian).
2. Search for the second account, save the contact, and open a direct conversation.
3. Send a message and show that it appears in the conversation.
4. Use the Memory action on a message and explain that extraction proposes a candidate which the user explicitly saves.
5. Send a second message and demonstrate one expiry mode.
6. Create a payment request and show the local mock flow only unless a correctly configured Daraja sandbox is being used.
7. Open the profile/preferences screen and explain the privacy settings.
8. Point to `docs/API.md` for endpoint contracts and `docs/DATABASE.md` for stored data.

## 7. Useful verification commands

Run these from the repository root (each command is run inside its own project directory):

```bash
cd server && npm install && npm test && npm run lint
cd ../mobile && flutter pub get && flutter analyze && flutter test
```

To build an Android package after analysis/tests pass:

```bash
flutter build apk
```

Do not claim tests/builds passed unless you have run them successfully in the environment used for the defense.
