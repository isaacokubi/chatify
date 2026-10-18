import test from 'node:test';
import assert from 'node:assert/strict';
import { unhideConversationForUser } from './conversation-visibility.js';

test('sending a message unhides only the sender conversation view', () => {
  const sender = 'user-a';
  const otherUser = 'user-b';
  assert.deepEqual(
    unhideConversationForUser([sender, otherUser], sender),
    [otherUser],
  );
});

test('sending a message preserves every other hidden user and does not mutate input', () => {
  const hiddenFor = ['user-a', 'user-b', 'user-c'];
  const result = unhideConversationForUser(hiddenFor, 'user-a');
  assert.deepEqual(result, ['user-b', 'user-c']);
  assert.deepEqual(hiddenFor, ['user-a', 'user-b', 'user-c']);
});

test('a user not in the hidden list does not change other users visibility', () => {
  assert.deepEqual(
    unhideConversationForUser(['user-b'], 'user-a'),
    ['user-b'],
  );
});
