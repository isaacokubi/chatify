import test from 'node:test';
import assert from 'node:assert/strict';
import {isMentionNotification, normalizeMentionIds} from './mentions.js';

test('mentions are unique, conversation-local, and cannot target the sender', () => {
  assert.deepEqual(normalizeMentionIds(['peer', 'peer'], ['sender', 'peer'], 'sender'), ['peer']);
  assert.deepEqual(normalizeMentionIds(undefined, ['sender', 'peer'], 'sender'), []);
  assert.equal(normalizeMentionIds(['outsider'], ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds(['sender'], ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds('peer', ['sender', 'peer'], 'sender'), null);
  assert.equal(normalizeMentionIds(Array(50).fill('peer'), ['sender', 'peer'], 'sender'), null);
});

test('mention notifications respect the mention preference independently of message alerts', () => {
  const mentioned = {_id: 'peer', notificationPreferences: {messages: true, mentions: true}};
  const mentionOnly = {_id: 'peer', notificationPreferences: {messages: false, mentions: true}};
  const disabled = {_id: 'peer', notificationPreferences: {messages: false, mentions: false}};
  assert.equal(isMentionNotification(mentioned, ['peer']), true);
  assert.equal(isMentionNotification(mentionOnly, ['peer']), true);
  assert.equal(isMentionNotification(disabled, ['peer']), false);
  assert.equal(isMentionNotification(mentioned, ['other']), false);
});
