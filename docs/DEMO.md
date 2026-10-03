# Chatify Defense Demo

Register Alice and Brian. Alice searches for Brian, starts a direct chat and sends: `Let's meet at the library tomorrow at 2 PM to discuss the project.` Use the Memory action to save the extracted event as `Project Meeting`, then open Memories. Send another message and choose `Delete after reading`; trigger the read flow and show the expired message is removed/hidden. Create a group, add a member, send a message and demonstrate administrator controls.

Password-reset delivery, Cloudinary uploads and push delivery require real provider configuration. Development image storage and notifications use mocks. Never use production users or real provider secrets for a demo. Push notifications require an FCM token registered through the authenticated `/api/devices` endpoint; the current Flutter UI does not yet request notification permission or register tokens.

Explain the innovations simply: Memory Cards turn useful conversational information into structured records; expiration gives a message a configurable application-level lifecycle.
