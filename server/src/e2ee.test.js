import test from 'node:test';
import assert from 'node:assert/strict';
import { isValidEncryptedPayload } from './e2ee.js';

const base64 = length => Buffer.alloc(length, 7).toString('base64');
const payloadFor = ids => JSON.stringify(Object.fromEntries(ids.map(id => [id, {
  nonce: base64(12),
  ciphertext: base64(24),
  mac: base64(16),
}])));

test('accepts valid encrypted envelopes for every conversation member', () => {
  assert.equal(isValidEncryptedPayload(payloadFor(['alice', 'bob']), ['bob', 'alice']), true);
});

test('rejects missing recipient envelopes', () => {
  assert.equal(isValidEncryptedPayload(payloadFor(['alice']), ['alice', 'bob']), false);
});

test('rejects extra envelopes that could leak to a removed member', () => {
  assert.equal(isValidEncryptedPayload(payloadFor(['alice', 'bob', 'former-member']), ['alice', 'bob']), false);
});

test('rejects malformed JSON and invalid nonce/MAC lengths', () => {
  assert.equal(isValidEncryptedPayload('{not-json', ['alice']), false);
  const badNonce = JSON.stringify({ alice: { nonce: base64(8), ciphertext: base64(8), mac: base64(16) } });
  assert.equal(isValidEncryptedPayload(badNonce, ['alice']), false);
  const badMac = JSON.stringify({ alice: { nonce: base64(12), ciphertext: base64(8), mac: base64(8) } });
  assert.equal(isValidEncryptedPayload(badMac, ['alice']), false);
});

test('rejects empty or oversized ciphertext and payloads', () => {
  const empty = JSON.stringify({ alice: { nonce: base64(12), ciphertext: '', mac: base64(16) } });
  assert.equal(isValidEncryptedPayload(empty, ['alice']), false);
  const tooLarge = JSON.stringify({ alice: { nonce: base64(12), ciphertext: base64(20001), mac: base64(16) } });
  assert.equal(isValidEncryptedPayload(tooLarge, ['alice']), false);
  assert.equal(isValidEncryptedPayload('x'.repeat(30001), ['alice']), false);
});
