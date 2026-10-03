import test from 'node:test';
import assert from 'node:assert/strict';
import {createResetToken,hashResetToken,resetExpiry,messageExpiry,expiresWhenRepliedTo,validPassword} from '../src/lifecycle.js';

test('password reset tokens are high entropy and stored as non-reversible hashes', () => {
  const token = createResetToken();
  assert.equal(token.length, 64);
  assert.notEqual(hashResetToken(token), token);
  assert.equal(hashResetToken(token), hashResetToken(token));
});

test('password reset expiry is 30 minutes', () => {
  assert.equal(resetExpiry(1000).getTime(), 1801000);
});

test('password validation respects bcrypt byte limits', () => {
  assert.equal(validPassword('short'), false);
  assert.equal(validPassword('long-enough'), true);
  assert.equal(validPassword('é'.repeat(40)), false);
});

test('message expiration is bounded and only set for AFTER_TIME', () => {
  assert.equal(messageExpiry('NONE', 30, 1000), undefined);
  assert.equal(messageExpiry('AFTER_TIME', 1, 1000).getTime(), 61000);
  assert.equal(messageExpiry('AFTER_TIME', 99999999, 1000).getTime(), 2592001000);
});

test('AFTER_REPLY expires the replied-to message', () => {
  assert.equal(expiresWhenRepliedTo({expiryType:'AFTER_REPLY'}), true);
  assert.equal(expiresWhenRepliedTo({expiryType:'NONE'}), false);
});
