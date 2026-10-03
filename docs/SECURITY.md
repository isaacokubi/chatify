# Chatify Security

Passwords are bcrypt-hashed. Password-reset tokens are random, stored as SHA-256 hashes, single-use, and expire after 30 minutes. Tokens are delivered only through the configured SMTP provider; they are not included in responses or logs. The public forgot-password response does not reveal whether an account exists.

REST and Socket.IO use JWT authentication. Production requires a strong `JWT_SECRET`. Server-side authorization protects private conversations, group administration, device-token ownership, and memory ownership. FCM registration tokens are scoped to the authenticated user, excluded from API user objects, and removed when FCM reports them invalid.

Helmet, rate limiting, input validation, payload limits, and HTTPS-origin allowlists provide baseline protections. Production `CLIENT_ORIGIN` must contain exact HTTPS frontend origins; wildcard CORS is only supported in development. Native requests without an `Origin` header remain supported.

SMTP, Cloudinary, and Firebase service-account credentials are environment-only. Do not commit `.env` files, Firebase service-account files, keys, API tokens, reset tokens, or build logs containing sensitive data. Configure `FIREBASE_SERVICE_ACCOUNT_JSON` as a private Render environment value rather than a file in the repository.

Cloudinary uploads validate supported image signatures and size before storage. Development data-URL mocks cannot be sent as production media messages. Message expiration is application-level removal/hiding, not cryptographic secure deletion.
