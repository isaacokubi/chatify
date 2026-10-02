# Chatify API

Authentication: POST `/api/auth/register`, POST `/api/auth/login`.

Users: GET `/api/users/search?q=...`.

Conversations: GET `/api/conversations`, POST `/api/conversations/direct`, POST `/api/conversations/group`.

Messages: GET `/api/conversations/:id/messages`, POST `/api/conversations/:id/messages`.

Memories: POST `/api/memories/extract`, POST `/api/memories`, GET `/api/memories`.

Protected endpoints require `Authorization: Bearer <JWT>`. Server-side membership and ownership checks are authoritative.

Socket events include `message:new`, `message:read`, `message:reaction`, `message:deleted`, `message:expired`, `typing:start`, `typing:stop`, `user:online`, `user:offline`, and `conversation:updated`.
