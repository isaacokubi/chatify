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

The Flutter Web hosting origin is not defined in this repository. Set `CLIENT_ORIGIN` only after choosing or identifying that frontend host. Until then, production browser origins are denied; native API clients are unaffected. The API Render URL is not the Flutter Web origin.

SMTP, Cloudinary, and Firebase adapters are implemented but require their corresponding provider configuration to deliver/store anything. With no SMTP configuration, production password-reset requests fail with HTTP 503. Without Cloudinary, uploads fail with HTTP 503. Without valid FCM configuration and registered device tokens, no push delivery is claimed. Development storage and notification providers are mocks; the development email mock never prints reset tokens.

The API exposes authenticated POST and DELETE `/api/devices` for FCM token registration/removal. The Flutter app does not yet request notification permission or register FCM tokens, so push delivery requires a client to register a token through this API.

Run `npm run seed` only against an explicitly selected development/demo Atlas database. Never seed production or commit production credentials.
