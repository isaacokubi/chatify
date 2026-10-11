# Chatify Project Walkthrough
## Plain-language guide for learning, demonstration, and tutor defense

This document explains Chatify in everyday language: what each part does, how a typical action travels through the system, why the main design choices matter, and what to say when demonstrating the project. It describes the intended architecture; it is not proof that every integration is configured or every test has passed. Verify environment-specific behavior before describing it as working in a live deployment.

## 1. Chatify in one minute

Chatify is a Flutter mobile communication app supported by a Node.js/Express API. It combines:

- **Chat:** direct and group conversations, text and media messages, replies, reactions, delivery/read state, and live updates.
- **Remember:** helps a user turn useful information in a conversation into a structured Memory Card, such as a task, event, payment, place, or note.
- **Let Go:** gives messages application-level expiry options, including no expiry, expiry after reading, after a time, or after a reply.
- **Chatify Pay:** supports payment requests and an M-Pesa flow through either a clearly labelled local mock provider or a configured Safaricom Daraja integration.
- **Account and privacy tools:** registration, sign-in, profiles, blocked users, password-reset flow, device tokens, and notification preferences.

The simplest way to explain the design is: **the mobile app is what the person uses; the API applies the rules; the database remembers records; and real-time events keep connected screens up to date.**

## 2. System map

~~~text
Person using the app
        |
        v
Flutter mobile app (mobile/)
  - screens and forms
  - local presentation state
  - HTTP requests and Socket.IO connection
        |
        | HTTPS/JSON + authenticated real-time connection
        v
Express API and Socket.IO (server/src/index.js)
  - validates incoming data
  - identifies the signed-in user
  - checks membership and ownership
  - applies message/payment rules
        |
        +-------------------> MongoDB via Mongoose
        |                      users, conversations, messages,
        |                      memories, reset records, payments
        |
        +-------------------> Configured provider adapters
                               email, media storage, push notices,
                               M-Pesa / Daraja
~~~

### What each part is responsible for

- **Flutter client (mobile/)** displays screens and collects user input. It sends requests and displays the server's response. Client-side checks improve the experience but do not replace backend security.
- **Express API (server/)** is the central decision-maker. It validates requests, checks identity and permissions, changes records, and returns results.
- **MongoDB and Mongoose** persist data. Mongoose schemas describe the shape of records and help enforce constraints.
- **Socket.IO** delivers live events such as new messages, typing indicators, and presence changes to authorized connected clients.
- **Provider modules** isolate external services behind reusable interfaces. A mock provider is useful for development but is not a real external delivery or transaction.
- **Environment configuration** supplies deployment-specific values and credentials. Secrets belong in environment variables, not committed source files.

## 3. Where to find the important code

| Path | What it is for |
|---|---|
| mobile/lib/main.dart | Main Flutter entrypoint, shared API client and state, and major application screens. |
| mobile/pubspec.yaml | Flutter package dependencies and app metadata. |
| server/src/index.js | Main Express/Socket.IO server, middleware, database models, API routes, callbacks, and background expiry handling. |
| server/src/auth.js | Reusable authentication middleware for verifying bearer tokens and loading the user. |
| server/src/payments.js | Payment-provider selection, phone/amount validation, payment-state rules, and callback outcome handling. |
| server/src/providers.js | Provider adapters for services such as email, storage, and notifications. |
| server/src/config.js | Runtime environment and client-origin/CORS configuration helpers. |
| server/src/lifecycle.js | Shared password/reset, expiry, credential-normalization, and graceful-shutdown helpers. |
| server/src/memory.js | Logic used to identify candidate information for Memory Cards. |
| server/src/seed.js and server/src/seedConfig.js | Demo/development data setup and its configuration. Use only as documented. |
| docs/API.md | API endpoint reference and request/response information. |
| docs/DATABASE.md | Overview of the stored entities and their relationships. |
| docs/ARCHITECTURE.md | High-level architecture notes. |
| docs/SECURITY.md | Security assumptions and defensive-design notes, if present in this checkout. |
| docs/DEMO.md | Demo instructions, including payment-provider setup guidance. |
| docs/CODE_WALKTHROUGH.md | Earlier code-reading guide with focused flow explanations. |

When a feature seems broken, trace it in this order: the screen or button in Flutter, the API request it sends, the matching server route, the model/provider used by that route, and the response or real-time event returned to the client.

## 4. How the main features connect

### 4.1 Registration, sign-in, and an authenticated session

1. A person enters registration or login details in the mobile app.
2. The app sends those details to the server over the API.
3. The server validates the input. For login, it compares the submitted password against the stored password hash.
4. On success, the server issues a signed JSON Web Token (JWT) and returns a safe user profile.
5. The app keeps the token for later requests and attaches it as a bearer token.
6. Protected server routes verify the token and load the account before continuing.

**Why this matters:** a screen showing a logged-in user is not enough to authorize a sensitive operation. The server must verify the token and check that the user may access the requested record.

### 4.2 Contacts and conversations

1. The signed-in user searches for another account and saves or opens a contact.
2. The app requests or creates a direct conversation through the API.
3. The server checks the participants and does not treat a client-supplied conversation ID as proof of membership.
4. The conversation record stores its participants and summary information.
5. The client loads messages for the selected conversation.

A conversation groups the participants and messages belonging to their discussion. Membership checks are important because knowing or guessing an ID should not grant access to someone else's conversation.

### 4.3 Sending and receiving a message

1. The user types a message and taps send.
2. The Flutter app sends the text and conversation identifier to the API.
3. The server validates the content and confirms the sender belongs to that conversation.
4. The server stores the message and updates the conversation's latest-message summary.
5. Socket.IO emits an event to the relevant conversation room.
6. Other connected members receive the event and update their screens without needing to refresh manually.

The database is the durable record; Socket.IO is the fast notification channel. If a device disconnects, it should fetch current data from the API when it reconnects rather than assuming it received every event.

### 4.4 Remember: making a Memory Card

1. The user chooses the memory action for a message or provides information.
2. The app asks the server to identify possible useful details.
3. The server returns candidate items such as a task, date, place, or note.
4. The user reviews the candidates and chooses what to save.
5. The app sends the chosen details to the API.
6. The server checks ownership and any linked conversation/source message, then stores the Memory Card.
7. The Memories screen loads the saved records for the current user.

**Important distinction:** a candidate produced by extraction is a suggestion. The user should review it; it should not automatically be treated as a verified fact or saved without the appropriate action.

### 4.5 Let Go: message expiry

A sender can choose an expiry policy for a message. The server stores the policy and, for timed expiry, the due time. Reading, replying, or a scheduled cleanup process can trigger the relevant expiry rule. The server updates the record and emits an event so connected screens can reflect the change.

**Security limitation:** this is application-level hiding/removal, not cryptographic secure deletion. It cannot prevent screenshots, copying, external backups, or a recipient recording the content before expiry. Do not describe it as a guarantee that all copies disappear.

### 4.6 Chatify Pay and M-Pesa

1. A requester creates a payment request with the intended payer, amount, phone number, and description.
2. The server validates the participants and amount and stores the request in a pending state.
3. The payer starts the payment flow.
4. In **mock mode**, the app demonstrates the flow locally. It does not send a real request to Safaricom and must remain clearly labelled as a demo.
5. In **Daraja mode**, the server requests an STK Push and records provider references returned by Safaricom.
6. Safaricom sends a callback to the server.
7. The server matches the callback to the pending payment, processes the outcome, and updates the status according to the verified result.

**Crucial distinction:** “request accepted” or “STK prompt initiated” does not mean that money was paid. A real payment should only be marked successful after the provider result is correctly matched and verified. Never expose Daraja credentials, callback secrets, or a real customer's payment details in a presentation.

### 4.7 Notifications and presence

The app can register a device's push-notification token with the backend when Firebase is configured. The backend's notification provider can then send supported push notifications. Socket.IO presence events are used for online/offline state while connected. These are separate mechanisms: Socket.IO is for live app events, while push notifications help alert a device when it is not actively viewing the conversation.

Firebase configuration and platform-specific setup are required before expecting push notifications to work on a real device. A missing optional Firebase setup should not be presented as proof that notification delivery has been tested.

## 5. Data model: what the database remembers

The server defines Mongoose models for the main records. In plain terms:

- **User:** account details, password hash, profile/privacy settings, blocked users, and notification preferences.
- **Conversation:** direct/group type, participants, group information, and latest-message summary.
- **Message:** sender, conversation, text or media metadata, reply/reaction information, delivery/read state, and expiry state.
- **Memory:** the owner, memory category, title/description, optional date/time/place, and optional source references.
- **SavedContact:** which user saved another user and any local display-name override.
- **PasswordReset:** a hashed reset token and its expiry time.
- **Payment:** requester, payer, amount, provider references, phone information, timestamps, and payment status.

These records are connected by identifiers. For example, a message points to a conversation, while the server checks that the current user belongs to that conversation before returning or changing the message. A memory belongs to a user. A payment identifies its requester and payer.

For the precise current fields and indexes, inspect the model definitions in server/src/index.js and the database notes in docs/DATABASE.md.

## 6. Security concepts to explain to a tutor

### Authentication versus authorization

- **Authentication** asks: “Who is this user?” Chatify uses login credentials and a signed JWT session.
- **Authorization** asks: “Is this user allowed to perform this action on this record?” The backend must check conversation membership, record ownership, and any role/operation restrictions on each protected route.

Being logged in does not automatically grant access to every user's data.

### Password hashing

Passwords should not be stored as readable text. Chatify uses bcrypt password hashes, allowing the server to check a submitted password without storing the original password. A password hash is still sensitive data and should never be returned to the mobile app.

### JWTs and protected requests

A JWT is a signed token used to represent the authenticated session. The server verifies the signature and expiry before trusting its claims. Keep the signing secret private, use HTTPS in deployment, and handle expired or revoked sessions appropriately.

### Ownership and membership checks

The backend must confirm that the authenticated user belongs to the requested conversation and owns or is authorized to access a memory, message, contact, or payment. IDs sent by a mobile client are input, not proof of permission.

### Input validation

The API should reject malformed identifiers, unsupported message types, oversized text, invalid phone numbers, and out-of-range payment amounts. Validation reduces errors and prevents clients from bypassing the expected rules by sending custom requests.

### CORS, Helmet, and rate limiting

- **CORS** limits which browser origins can read responses. It is not a login system and does not stop non-browser clients from making requests.
- **Helmet** adds defensive HTTP headers.
- **Rate limiting** limits how frequently a client can call selected endpoints and can reduce some brute-force or abuse attempts.

These protections are useful layers, not a substitute for authentication, authorization, secure configuration, monitoring, and testing.

### Secrets and provider configuration

API keys, JWT secrets, database credentials, SMTP passwords, Firebase credentials, and Daraja credentials belong in environment configuration or a suitable secret manager. Do not commit real secrets or paste them into screenshots, demo slides, logs, or tutor submissions. Use test accounts and sandbox/mock providers for demonstrations.

### Payment callback integrity

The server must not trust a success message from the mobile app. It should correlate the provider callback to the original request, validate the result and identifiers, and avoid processing the same callback twice. A pending request is not a completed payment.

### Privacy and expiry limitations

Blocking, read receipts, privacy settings, and expiry features only provide the protection implemented by the backend and client. Explain their actual scope honestly. Application-level expiry does not guarantee secure erasure from every device or external copy.

## 7. Tutor demonstration plan

Use two test accounts, such as Alice and Brian, and avoid real private information.

1. **Introduce the architecture.** Show the Flutter app folder, the Express server folder, and the docs folder.
2. **Register or sign in.** Explain how the client sends credentials and how the server returns a session token.
3. **Create a conversation.** Find the second test user and open a direct chat. Explain participants and membership checks.
4. **Send a message.** Show it appearing in the conversation and explain that the server stores it while Socket.IO delivers live updates.
5. **Demonstrate Remember.** Use a message containing a sample task/event, review the extracted candidate, save it, and open Memories.
6. **Demonstrate Let Go.** Send a separate test message with an expiry option and explain the difference between application-level expiry and guaranteed secure deletion.
7. **Show Chatify Pay in mock mode.** Point out the demo label and explain that a local mock does not transfer money. Only use Daraja sandbox if it has been configured and verified.
8. **Show privacy/profile settings.** Explain which preferences are client display choices and which rules are enforced by the server.
9. **Explain the code path.** Trace one action from the Flutter screen to its API route, model/provider, and response/event.
10. **Be honest about evidence.** State which tests, builds, integrations, and devices you personally verified. Do not claim a check passed if it was not run.

## 8. Likely tutor questions and short answers

**Q: Why use Flutter?**  
A: Flutter lets the project build a mobile interface from a shared Dart codebase and provides widgets and packages for forms, navigation, HTTP, and device capabilities.

**Q: Why have a backend if the app already has screens?**  
A: The backend centralizes trusted rules, validates data, checks permissions, persists records, and integrates with services. Client-side logic alone can be bypassed.

**Q: What does Socket.IO add?**  
A: It provides live events so connected users can see messages and presence changes without repeatedly refreshing the screen. Stored API/database data remains important for reconnecting and history.

**Q: What is the purpose of Memory Cards?**  
A: They help users turn useful conversational details into structured, retrievable records. Extracted candidates need user review.

**Q: Does Let Go guarantee a message is permanently erased?**  
A: No. It implements application-level expiry/removal. It cannot erase screenshots, copied text, or every external copy.

**Q: Does an STK Push mean a payment succeeded?**  
A: No. Initiation only means the request was submitted. The backend must process the matching provider callback before treating it as successful.

**Q: What is the difference between authentication and authorization?**  
A: Authentication identifies the account; authorization decides what that account is allowed to access or change.

**Q: What happens if the phone disconnects?**  
A: It may miss live Socket.IO events while offline. When it reconnects, it should load current records from the API rather than relying only on events it received earlier.

**Q: How would you investigate a broken feature?**  
A: Reproduce the issue, inspect the mobile action and request, check the server route and validation, inspect relevant database/provider behavior, then check the response and real-time events. Review logs without exposing secrets or private user data.

## 9. Safe verification commands

Run these commands from the repository root. Each project has its own dependencies and checks.

Backend:

~~~bash
cd server
npm install
npm test
npm run lint
~~~

Mobile:

~~~bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk
~~~

If a script does not exist or a command fails, record the actual result and investigate it; do not describe it as a passing check. Build and test outcomes depend on the current code, installed SDK versions, configuration, and environment.

## 10. Final presentation checklist

- [ ] I can explain what the mobile app, API, database, and provider modules each do.
- [ ] I can trace one message from the screen to storage and back to another user.
- [ ] I can explain the difference between authentication and authorization.
- [ ] I understand that mock payments are not real payments and that STK initiation is not payment confirmation.
- [ ] I can describe the limits of message expiry honestly.
- [ ] I have prepared test accounts and removed private or secret values from screenshots.
- [ ] I have run the checks I intend to mention and can show their actual results.
- [ ] I can find the relevant source file and explain the main logic in my own words.

**Tip:** Use this guide to learn the flow, then explain it naturally. A strong project defense shows that you understand why the parts connect, not just that you can read comments aloud.
