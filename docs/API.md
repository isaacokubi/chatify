# Chatify API

Authentication: POST `/api/auth/register`, POST `/api/auth/login`, GET `/api/auth/me`, POST `/api/auth/change-password`, POST `/api/auth/forgot-password`, POST `/api/auth/reset-password`. Passwords must be 8–72 UTF-8 bytes. Reset tokens are random, stored hashed, single-use, and expire after 30 minutes. Production sends them through the configured SMTP transport and never returns or logs a token. With missing production email settings, forgot-password returns HTTP 503 before looking up the account; SMTP delivery failures use the same generic response for known and unknown accounts.

Users: GET `/api/users/search?q=...` performs case-insensitive partial matching against names and email addresses; queries shorter than two characters return no results.

Conversations: GET `/api/conversations`, GET `/api/conversations/:id`, POST `/api/conversations/direct`, POST `/api/conversations/group`. Group membership and role changes require group admin access; only members can read messages or join Socket.IO rooms. Direct conversations use a canonical participant key to prevent duplicate threads.

Messages: GET `/api/conversations/:id/messages` supports bounded text search; POST `/api/conversations/:id/messages`; POST `/api/messages/:id/reactions`; POST `/api/messages/:id/delivered`; POST `/api/messages/:id/read`. `AFTER_REPLY` expires the message being replied to. Timed expiry is bounded to 30 days and is broadcast to active clients. POST `/api/media` accepts JPEG, PNG or WebP images up to 650 KiB and validates the encoded image signature. Production stores images in Cloudinary and only accepts secure HTTPS delivery URLs in messages; data URL media is restricted to development mocks. Missing production Cloudinary configuration returns HTTP 503.

Push devices: authenticated POST `/api/devices` registers a device FCM token; authenticated DELETE `/api/devices` removes the current user's token. A user may register up to 20 devices. Tokens are not included in user/API responses. The server sends generic new-message notifications only to active tokens when that user's message notification preference is enabled. The Flutter client does not currently request FCM permission or register its device token; clients must use these endpoints until that app-side flow is added.

Memories: POST `/api/memories/extract`, POST `/api/memories`, GET `/api/memories`, PATCH `/api/memories/:id`, DELETE `/api/memories/:id`. The API assigns memory ownership and checks access to any linked conversation and source message.

Protected endpoints require `Authorization: Bearer <JWT>`. Server-side membership and ownership checks are authoritative. Production CORS allows only origins listed in `CLIENT_ORIGIN` (comma-separated HTTPS origins); `*` is supported only in development. Native clients without a browser Origin remain supported.

Socket events include `message:new`, `message:read`, `message:reaction`, `message:expired`, `typing:start`, `typing:stop`, `user:online`, `user:offline`, and `conversation:updated`. Clients can join only conversations where they are members; typing events are restricted to joined rooms.
