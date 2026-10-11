# Chatify — Chat. Remember. Let Go.

Chatify is a final-year-project mobile communication system built around real-time **Chat**, structured conversational **Memory**, and configurable message **Expiration**.

## Repository
- mobile/ — Flutter/Dart client
- server/ — Node.js/Express/Socket.IO API
- docs/ — architecture, API, database, development, security and demo notes
- `docs/CODE_WALKTHROUGH.md` — plain-language explanation of the system, main files, request flows and how to explain the project during a defense.

## Core innovations
- **Remember:** deterministic local extraction identifies event, task, payment, place and note candidates that users can save as Memory Cards.
- **Let Go:** messages support NONE, AFTER_READ, AFTER_TIME and AFTER_REPLY application-level lifecycles.

## Backend
```bash
cd server
cp .env.example .env
npm install
npm test
npm run lint
npm start
```
Set MONGODB_URI to MongoDB Atlas and JWT_SECRET to a long random value.

## Mobile
```bash
cd mobile
flutter pub get
flutter analyze
flutter test
flutter build apk
```
The sample Android-emulator API address is http://10.0.2.2:5000. Set a different API address at build/run time with `--dart-define=CHATIFY_API=https://your-api.example`; a physical device must use a reachable development LAN address.

## Demo
Register Alice and Brian. From Contacts search for the other account and start a direct conversation. Send: “Let's meet at the library tomorrow at 2 PM to discuss the project.” Use the sparkle action to extract and save the candidate, then open Memories. Send another message and choose Delete after reading, Delete after 1 hour, or Delete after reply.

### Chatify Pay demo

With the default `MPESA_ENV=mock`, request an amount from the other conversation member and tap **Pay with M-Pesa**. The UI labels the request **Local demo**; no Safaricom transaction is made and the app never collects an M-Pesa PIN. To use Daraja sandbox, follow [docs/DEMO.md](docs/DEMO.md). Never select production mode for a classroom demo.

Payment requests move from `PENDING` to `SUCCESS`, `FAILED`, or `CANCELLED`. A real request stays pending until Daraja's callback confirms its result; an accepted STK request is not proof that money was received.

## Production providers
MongoDB Atlas is supported directly through configuration. SMTP password-reset email, Cloudinary image storage, Firebase Admin/FCM message notifications, and Daraja STK Push use production adapters behind small provider boundaries. Set their environment variables before enabling those features. Development storage, email, notification and payment providers remain mocks; the development email mock never prints reset tokens, and mock payments are labeled and never contact Safaricom. The Flutter app registers its FCM token with the authenticated `/api/devices` endpoint when Firebase is configured, retries on token refresh, unregisters the active token on logout, and opens authorized conversations from notification taps. Add the platform-specific Firebase configuration before expecting device notifications; Firebase initialization failures are non-fatal so development chat remains usable without credentials.

Set a persistent `JWT_SECRET` in the local environment if demo sessions must survive server restarts; production refuses to start without a 32-character secret. Production CORS requires exact HTTPS Flutter Web origins in `CLIENT_ORIGIN`; the Flutter Web host is not currently specified in this repository.

## Security
Passwords are bcrypt-hashed. JWTs protect REST and Socket.IO. Server-side membership/admin checks protect conversations and groups. Helmet, CORS and rate limiting are enabled. Secrets are excluded by Git ignore rules. Message expiration is application-level removal/hiding and is not cryptographic secure deletion.

See docs/ for the defense-oriented architecture, API, database, development, security and demo notes.
