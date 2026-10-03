# Chatify Database

Core MongoDB collections are users, conversations, messages, memories and password resets. Small relationships such as participants, admins, reactions, read state, notification preferences, and FCM device-token lists are embedded where practical. FCM tokens are excluded from user/API responses. Message notifications are sent through the notification provider and are not persisted as a separate collection.

Important indexes cover unique normalized user email, text search, conversation participants, a sparse unique canonical direct-conversation key, message conversation/createdAt and expiry fields, memory ownership, and expiring one-use password-reset token hashes. MongoDB Atlas is the production database; no local database is assumed for deployment.
