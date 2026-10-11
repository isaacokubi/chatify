# Chatify Architecture

Chatify uses a practical client/server architecture. Flutter renders the mobile experience and calls a REST API for durable operations. Socket.IO supplies transient real-time events. Express middleware authenticates requests, route handlers apply business rules, and Mongoose persists MongoDB Atlas data.

Flutter → REST/Socket.IO → Express → services/models → MongoDB Atlas.

Message → deterministic memory extraction → user confirmation → Memory Card. Message → expiry policy → server processing → hidden/removed message.

SMTP, Cloudinary, Firebase Admin/FCM, and Daraja have adapters isolated behind provider boundaries. Development mocks remain available without provider credentials. When Firebase native configuration is present, Flutter registers and refreshes FCM tokens through authenticated API routes.
