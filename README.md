# Chatify — Chat. Remember. Let Go.

Chatify is a final-year-project mobile communication system built around real-time **Chat**, structured conversational **Memory**, and configurable message **Expiration**.

## Repository
- mobile/ — Flutter/Dart client
- server/ — Node.js/Express/Socket.IO API
- docs/ — architecture, API, database, development, security and demo notes

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

## Production providers
MongoDB Atlas is supported directly through configuration. SMTP password-reset email, Cloudinary image storage, and Firebase Admin/FCM message notifications use production adapters behind provider interfaces. Set their environment variables before enabling those features. Development storage, email, and notification providers remain mocks; the development email mock never prints reset tokens. Push notifications also require a client to register its FCM token through the authenticated `/api/devices` endpoint; the Flutter app does not yet perform that registration.

Set a persistent `JWT_SECRET` in the local environment if demo sessions must survive server restarts; production refuses to start without a 32-character secret. Production CORS requires exact HTTPS Flutter Web origins in `CLIENT_ORIGIN`; the Flutter Web host is not currently specified in this repository.

## Security
Passwords are bcrypt-hashed. JWTs protect REST and Socket.IO. Server-side membership/admin checks protect conversations and groups. Helmet, CORS and rate limiting are enabled. Secrets are excluded by Git ignore rules. Message expiration is application-level removal/hiding and is not cryptographic secure deletion.

See docs/ for the defense-oriented architecture, API, database, development, security and demo notes.
