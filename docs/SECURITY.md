# Chatify Security

Passwords are bcrypt-hashed. REST and Socket.IO connections use JWT authentication. Server-side authorization protects private conversations and group administration. Helmet, CORS, rate limiting, validation and bounded payloads provide baseline protection. Secrets are environment variables and excluded from source control.

Message expiration is application-level removal/hiding, not cryptographic secure deletion.
