# Development

Copy `server/.env.example` to `server/.env` and set a development MongoDB Atlas URI and a long development JWT secret. The sample URI is a placeholder; do not use localhost MongoDB for this project. Then run:

```sh
cd server
npm ci
npm run lint
npm test
npm start
```

For Flutter, run `cd mobile && flutter pub get && flutter analyze && flutter test`. Build releases with:

```sh
flutter build web --release --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
flutter build linux --release --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
flutter build apk --release --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
```

## Production environment checklist

Set these as private Render environment variables. Never put real values in Git, docs, logs, or chat.

| Variable | Production requirement |
| --- | --- |
| `NODE_ENV` | Explicitly set to `production`; the server refuses to start if this is missing or unsupported |
| `PORT` | Leave to Render's assigned port |
| `MONGODB_URI` | MongoDB Atlas connection URI with least-privilege credentials |
| `JWT_SECRET` | Existing strong secret, at least 32 characters; do not rotate as part of routine setup |
| `JWT_EXPIRES_IN` | Optional JWT lifetime (defaults to `7d`) |
| `CLIENT_ORIGIN` | Exact HTTPS origin(s) serving Flutter Web, comma-separated; do not use `*`. Legacy fallback names `CLIENT_ORIGINS` and `CLIENT_URL` are still accepted. |
| `SMTP_URL` | SMTP or SMTPS URL, with credentials URL-encoded |
| `SMTP_FROM` | Verified sender address/name accepted by the email provider |
| `CLOUDINARY_URL` | Cloudinary URL containing cloud name and API credentials |
| `FCM_PROJECT_ID` | Firebase project ID |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Entire service-account JSON as a private single-line environment value; never commit its file |
| `MPESA_ENV` | Explicitly set `production` before real production Daraja calls; sandbox uses `sandbox`, local demos use `mock` |
| `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET` | Credentials from the Daraja app; store as private values |
| `MPESA_SHORTCODE`, `MPESA_PASSKEY` | Lipa na M-Pesa Online shortcode/passkey for the selected environment |
| `MPESA_CALLBACK_URL` | Public HTTPS URL ending in `/api/payments/daraja/callback` |
| `MPESA_TRANSACTION_TYPE` | `CustomerPayBillOnline` or `CustomerBuyGoodsOnline`, matching the configured shortcode |

The Flutter Web hosting origin is not defined in this repository. Set `CLIENT_ORIGIN` only after choosing or identifying that frontend host. Until then, production browser origins are denied; native API clients are unaffected. The API Render URL is not the Flutter Web origin.

SMTP, Cloudinary, and Firebase adapters are implemented but require their corresponding provider configuration to deliver/store anything. With no SMTP configuration, production password-reset requests fail with HTTP 503. Without Cloudinary, uploads fail with HTTP 503. Without valid FCM configuration and registered device tokens, no push delivery is claimed. Development storage and notification providers are mocks; the development email mock never prints reset tokens.

The API exposes authenticated POST and DELETE `/api/devices` for FCM token registration/removal. The Flutter app requests notification permission, registers the current FCM token, handles token refresh, unregisters the active token at logout, and routes notification taps to a conversation after checking the authenticated conversation list. For Android, add the Firebase project configuration (including `google-services.json` and the required FlutterFire/Gradle setup) for the same project configured by `FCM_PROJECT_ID` and `FIREBASE_SERVICE_ACCOUNT_JSON`. Firebase setup is optional in development; without native Firebase configuration, push notifications remain unavailable while normal chat continues to work.

The demo seed command is guarded: it requires `NODE_ENV=development`, `CHATIFY_SEED_DEMO=YES`, an explicitly selected `MONGODB_URI`, and `DEMO_SEED_PASSWORD` (12–72 UTF-8 bytes). The password is never printed. Use only a disposable development/demo database; the seeder refuses other environments and has no built-in account password. Never seed production or commit credentials.

## Payments and test commands

The default payment provider is a clearly labeled local mock (`MPESA_ENV=mock`); it makes no outbound payment call and works without credentials. Daraja sandbox needs an app's consumer key/secret, sandbox shortcode/passkey, transaction type and a public HTTPS callback URL. See [DEMO.md](DEMO.md) for the full setup and tunnel requirements. Backend payment/provider unit tests use mocked HTTP and never initiate a real payment. Run `npm test` and `npm run lint` in `server/`; run `flutter pub get`, `flutter analyze`, and `flutter test` in `mobile/`.
