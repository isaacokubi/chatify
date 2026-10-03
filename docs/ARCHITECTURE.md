# Chatify Architecture

Chatify uses a practical client/server architecture. Flutter renders the mobile experience and calls a REST API for durable operations. Socket.IO supplies transient real-time events. Express middleware authenticates requests, route handlers apply business rules, and Mongoose persists MongoDB Atlas data.

Flutter → REST/Socket.IO → Express → services/models → MongoDB Atlas.

Message → deterministic memory extraction → user confirmation → Memory Card. Message → expiry policy → server processing → hidden/removed message.

SMTP, Cloudinary, and Firebase Admin/FCM have production adapters isolated behind provider boundaries. Development mocks remain available without provider credentials. FCM tokens are registered through authenticated API routes; Flutter-side permission/token registration remains to be connected.
