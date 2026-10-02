# API
Health: GET /health

Auth: POST /api/auth/register, POST /api/auth/login, GET /api/auth/me
Users: GET /api/users/search?q=..., PATCH /api/users/me
Conversations: GET /api/conversations, POST /api/conversations/direct, POST /api/conversations/group, POST/DELETE /api/conversations/:id/members
Messages: GET/POST /api/conversations/:id/messages, POST /api/messages/:id/reactions, POST /api/messages/:id/read
Memories: GET/POST /api/memories, POST /api/memories/extract, PATCH/DELETE /api/memories/:id

Socket events include conversation:join, message:new, message:read, message:reaction, typing:start and typing:stop.
