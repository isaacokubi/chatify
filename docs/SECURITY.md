# Chatify Security

Passwords are bcrypt-hashed. Password reset tokens are random, stored as SHA-256 hashes, one-use, and expire after 30 minutes. REST and Socket.IO connections use JWT authentication; socket room joins verify current membership. Server-side authorization protects private conversations, group administration and memory ownership. Helmet, CORS, rate limiting, validation and bounded payloads provide baseline protection. Secrets are environment variables and excluded from source control. Production must set a strong JWT_SECRET and a restricted CLIENT_ORIGIN.

Message expiration is application-level removal/hiding, not cryptographic secure deletion.
