# Development

Copy `server/.env.example` to `server/.env`, configure MongoDB Atlas and a development JWT secret, then run `cd server && npm install && npm test && npm run lint && npm start`.

For mobile run `cd mobile && flutter pub get && flutter analyze && flutter test`.

Run `npm run seed` only against an explicitly selected development/demo database. Never commit production credentials.
