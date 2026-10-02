# Chatify Database

Core MongoDB collections are users, conversations, messages, memories and notifications. Small relationships such as participants, admins, reactions and read state are embedded where practical.

Important indexes cover user email, conversation participants, message conversation/createdAt and expiry fields, plus memory user/conversation access patterns.
