# Chatify Database

Core MongoDB collections are users, conversations, messages, memories and notifications. Small relationships such as participants, admins, reactions and read state are embedded where practical.

Important indexes cover unique normalized user email, text search, conversation participants, a sparse unique canonical direct-conversation key, message conversation/createdAt and expiry fields, memory ownership, and expiring one-use password-reset token hashes. MongoDB Atlas is the production database; no local database is assumed for deployment.
