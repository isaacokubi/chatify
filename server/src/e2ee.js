/**
 * Structural validation for client-encrypted Chatify text messages.
 *
 * The API cannot decrypt or verify message plaintext. This validator only checks
 * envelope shape, nonce/MAC lengths and that every current conversation member
 * has exactly one recipient envelope.
 */
export function isValidEncryptedPayload(payload, participantIds, maxCipherBytes = 20000) {
  if (typeof payload !== 'string' || payload.length < 20 || payload.length > 30000) return false;
  let envelopes;
  try {
    envelopes = JSON.parse(payload);
  } catch {
    return false;
  }
  if (!envelopes || typeof envelopes !== 'object' || Array.isArray(envelopes)) return false;
  const members = [...new Set(participantIds.map(String))].sort();
  const recipients = Object.keys(envelopes).sort();
  if (members.length !== recipients.length || members.some((id, index) => id !== recipients[index])) return false;
  const isBase64 = value => typeof value === 'string' &&
    value.length > 0 &&
    /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value);
  return members.every(id => {
    const envelope = envelopes[id];
    if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)) return false;
    if (!isBase64(envelope.nonce) || !isBase64(envelope.ciphertext) || !isBase64(envelope.mac)) return false;
    const nonce = Buffer.from(envelope.nonce, 'base64');
    const ciphertext = Buffer.from(envelope.ciphertext, 'base64');
    const mac = Buffer.from(envelope.mac, 'base64');
    return nonce.length === 12 && ciphertext.length > 0 &&
      ciphertext.length <= maxCipherBytes && mac.length === 16;
  });
}
