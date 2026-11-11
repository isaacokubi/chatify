# Chatify Deployment Guide

## Deployment components

- **API:** Node.js 22+ Express service, deployed separately from the Flutter client. The documented hosted API is `https://chatify-api-c1eh.onrender.com`; verify the current deployment and deployed SHA before relying on it.
- **Web client:** Flutter Web build deployed to the chosen HTTPS frontend host. The API's `CLIENT_ORIGIN` must list the exact browser origin(s); the API host is not the frontend origin.
- **Android:** Flutter Android project and release signing workflow are documented in [ANDROID_APK_RELEASE.md](../mobile/ANDROID_APK_RELEASE.md).

## API deployment configuration

Use a private hosting secret store. Never commit real values. See [DEVELOPMENT.md](DEVELOPMENT.md) and [server/.env.example](../server/.env.example) for the complete variable inventory.

Required production configuration includes:
- `NODE_ENV=production`
- `MONGODB_URI` for MongoDB Atlas with least-privilege credentials
- `JWT_SECRET` with the required entropy/length
- `CLIENT_ORIGIN` containing exact HTTPS browser origins, never wildcard
- a configured public API URL and the appropriate SMTP/media/FCM/payment provider values only when those features are enabled
- separate school, platform and merchant payment credentials/tokens as required by the specific flow

Do not enable a provider simply because its environment variables exist. Verify credentials, callback ownership, signature/token validation, idempotency, settlement and reconciliation.

## Flutter Web

From `mobile/`, resolve dependencies and build with the approved API host:

```sh
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build web --release --dart-define=CHATIFY_API=https://<approved-api-host>
```

Deploy the generated `build/web` directory to the selected HTTPS frontend host. Add that exact origin to API `CLIENT_ORIGIN`. Verify sign-in, session restore, school/business workspace routing, CORS, file delivery and logout against the deployed API.

## Android

Use the existing committed Android project and the signing instructions in [Android APK release](../mobile/ANDROID_APK_RELEASE.md). Keep the existing production signing key outside Git. Debug APKs are for installation testing only and are not production releases.

## Health, rollback and release evidence

- Verify the deployed API SHA, service startup, database connectivity and the actual health/readiness endpoints implemented by the deployed build.
- Verify web origin, CORS and TLS from a real browser.
- Keep the previous known-good API and frontend artifacts for rollback.
- Do not roll back database schema changes without a tested compatibility/restore plan.
- Record release SHA, environment configuration names (not values), CI run URLs, smoke-test evidence and rollback owner in the release record.

## Current limitations

Hosting credentials, provider accounts, live tenant data, production monitoring and the selected frontend origin are outside this repository. A successful GitHub build does not prove a production deployment or live service acceptance.
