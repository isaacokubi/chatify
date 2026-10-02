# Security
Passwords are bcrypt-hashed. JWTs expire after seven days. REST and Socket.IO require verified identity. Conversation membership and group-admin checks are performed server-side. Input sizes are bounded, Helmet and rate limiting are enabled, and secrets are excluded by .gitignore.

Cloudinary, Firebase/FCM, SMTP and optional AI providers must be configured through environment variables. Message expiration is application-level removal/hiding and must not be marketed as secure cryptographic erasure.
