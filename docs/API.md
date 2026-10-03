# Chatify API

Authentication: POST `/api/auth/register`, POST `/api/auth/login`, GET `/api/auth/me`, POST `/api/auth/change-password`, POST `/api/auth/forgot-password`, POST `/api/auth/reset-password`. Passwords must be 8–72 UTF-8 bytes. Reset tokens are random, stored hashed, expire after 30 minutes, and are delivered through the email provider adapter. In development, the mock adapter writes the token to the server console; production delivery requires an injected email transport. Responses do not reveal whether an email is registered.

Users: GET `/api/users/search?q=...`.

Conversations: GET `/api/conversations`, GET `/api/conversations/:id`, POST `/api/conversations/direct`, POST `/api/conversations/group`. Group membership and role changes require group admin access; only members can read messages or join Socket.IO rooms. Direct conversations use a canonical participant key to prevent duplicate threads.

Messages: GET `/api/conversations/:id/messages` supports bounded text search; POST `/api/conversations/:id/messages`; POST `/api/messages/:id/reactions`; POST `/api/messages/:id/delivered`; POST `/api/messages/:id/read`. `AFTER_REPLY` expires the message being replied to. Timed expiry is bounded to 30 days and is broadcast to active clients. Media uploads accept JPEG, PNG or WebP through POST `/api/media`; mobile can upload a selected image or share a secure HTTPS URL through the storage adapter.

Memories: POST `/api/memories/extract`, POST `/api/memories`, GET `/api/memories`, PATCH `/api/memories/:id`, DELETE `/api/memories/:id`. The API assigns memory ownership and checks access to any linked conversation and source message.

Protected endpoints require `Authorization: Bearer <JWT>`. Server-side membership and ownership checks are authoritative.

Socket events include `message:new`, `message:read`, `message:reaction`, `message:expired`, `typing:start`, `typing:stop`, `user:online`, `user:offline`, and `conversation:updated`. Clients can join only conversations where they are members; typing events are restricted to joined rooms.
