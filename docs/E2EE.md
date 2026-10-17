# Chatify end-to-end encryption (E2EE)

## Current implementation scope

The mobile client encrypts **new text-message bodies** before sending them to the API. It uses:

- X25519 for client-side Diffie–Hellman key agreement
- HKDF-SHA-256 to derive a message-encryption key
- AES-256-GCM for confidentiality and integrity
- a fresh 96-bit nonce for every recipient envelope
- conversation ID and recipient ID as authenticated additional data
- Flutter Secure Storage for the device-local private-key seed

The API accepts encrypted text payloads only for new text messages and stores a generic conversation preview instead of message content. The server receives public keys and ciphertext, never the clear text of new text messages. The client creates one envelope per current conversation member, so direct and group text messages can be decrypted only by members who hold their corresponding private keys.

## Important limits — do not describe this as a complete secure messenger yet

1. **Legacy messages:** messages created before this change may still contain plaintext in MongoDB. This code does not retroactively encrypt old records. Existing server-side backups may also contain legacy plaintext.
2. **Attachments:** image/file uploads and media URLs are not end-to-end encrypted by this text-message implementation. Do not send sensitive material as an attachment until attachment encryption is implemented.
3. **Multi-device recovery:** the private key is stored locally. A second device cannot decrypt existing messages just by logging into the account. The API refuses silent key replacement; a secure, user-approved transfer/recovery flow is still needed.
4. **Forward secrecy:** this initial design uses long-lived account key agreement keys. It does not provide a ratcheting protocol or forward secrecy comparable to Signal's Double Ratchet. A compromised long-lived private key may expose recorded ciphertexts.
5. **Memory Cards:** encrypted message text is excluded from server-side automatic memory extraction so the clear text is not sent to the server for suggestions. Memory-card content is not yet end-to-end encrypted at rest.
6. **Key verification:** the current implementation does not provide safety-number / QR verification or protection against a malicious server replacing public keys before users verify them.
7. **Build and penetration tests:** do not treat this as production-audited cryptography. Run Flutter analyze/tests, test two accounts on separate devices, verify plaintext is absent from network requests/database records, test altered ciphertext, and obtain an independent security review before marketing E2EE as a production security guarantee.

## Device setup and behavior

On sign-in, the app creates a random X25519 private-key seed in platform secure storage if no server key exists, then registers only the public key through `PUT /api/users/me/encryption-key`. If the account already has a public key but the current device lacks the matching private key, the app refuses to overwrite the registered key. That is intentional: silently rotating the key would make existing messages unreadable.

Every conversation participant must use a compatible version and have a registered key before the sender can send encrypted text. The recipient decrypts locally after history is fetched or a Socket.IO message arrives. Authentication-tag failure or a missing key results in a locked-message placeholder, not a plaintext fallback.

## Production rollout checklist

- [ ] Add encrypted attachment uploads and local decryption.
- [ ] Add encrypted key backup / device transfer with user-controlled recovery.
- [ ] Adopt a reviewed ratcheting protocol for forward secrecy and key rotation.
- [ ] Add verified identity keys / safety numbers to prevent silent key substitution.
- [ ] Encrypt Memory Cards locally before any server persistence.
- [ ] Provide a safe migration or explicit legacy-message warning for pre-E2EE records.
- [ ] Add automated tests for key agreement, tampering, nonce handling, authorization, and plaintext leakage.
- [ ] Run `flutter pub get`, `flutter analyze`, `flutter test`, `npm test`, and `npm run lint`; then validate on real devices.
- [ ] Review backups, logs, analytics, crash reporting, push payloads, and search indexing for accidental message-content leakage.
