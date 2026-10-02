# Architecture
Flutter is the mobile client. Express exposes REST APIs. Socket.IO carries transient real-time events. MongoDB Atlas persists users, conversations, messages and memories. JWT is verified by both HTTP middleware and the socket handshake.

The project deliberately keeps domain rules simple enough for a final-year defense. Memory extraction is deterministic and local: regular expressions identify event, task, payment and place candidates. Message expiration is an application-level lifecycle rule, not cryptographic secure deletion.
