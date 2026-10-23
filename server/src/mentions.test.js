import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeMentionIds} from './mentions.js';

test('mentions are unique, conversation-local, and cannot target the sender', () => {
  assert.deepEqual(normalizeMentionIds(['peer', 'peer'], ['sender', 'peer'], 'sender'), ['peer']);
  assert.deepEqual(normalizeMentionIds(undefined, ['sender', 'peer'], 'sender'), []);
  assert.equal(normalizeMentionIds(['outsider'], ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds(['sender'], ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds('peer', ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds(Array(50).fill('peer'), ['sender', 'peer'], 'sender'), null);
});
