import test from 'node:test';
import assert from 'node:assert/strict';
import {createCallSignaling} from './call-signaling.js';

function harness({blocked = [], validConversation = true} = {}) {
  const handlers = new Map();
  const emitted = [];
  const socket = {on: (event, fn) => handlers.set(event, fn), emit: (event, payload) => emitted.push({to:'self', event, payload})};
  const io = {to: room => ({emit: (event, payload) => emitted.push({to:room, event, payload})})};
  const conversation = {_id:'conversation123', participants:['alice12345678901234567890','bob123456789012345678901'], type:'direct'};
  const Conversation = {findOne: query => ({select: () => ({lean: async () => validConversation && query.participants === query.participants && conversation.participants.includes(String(query.participants)) ? conversation : (validConversation && query.participants && conversation.participants.includes(query.participants) ? conversation : null)})})};
  // Mongoose's {participants: userId} matches array membership. Fake that behavior explicitly.
  Conversation.findOne = query => ({select: () => ({lean: async () => validConversation && conversation._id === query._id && conversation.participants.includes(String(query.participants)) ? conversation : null})});
  const User = {find: () => ({select: () => ({lean: async () => [
    {_id:'alice12345678901234567890', status:'active', blockedUsers: blocked.includes('alice') ? ['bob123456789012345678901'] : []},
    {_id:'bob123456789012345678901', status:'active', blockedUsers: blocked.includes('bob') ? ['alice12345678901234567890'] : []},
  ]})})};
  const service = createCallSignaling({io, Conversation, User, isValidObjectId: value => value === 'conversation123', now: () => 1000});
  service.register(socket, 'alice12345678901234567890');
  return {handlers, emitted, service};
}

const alice = 'alice12345678901234567890';
const bob = 'bob123456789012345678901';

test('rejects invalid call request', async () => {
  const h = harness();
  await h.handlers.get('call:invite')({callId:'bad', conversationId:'conversation123', calleeId:bob, callType:'video'});
  assert.equal(h.emitted.at(-1).event, 'call:error');
});

test('routes an authorized call invite to the recipient', async () => {
  const h = harness();
  await h.handlers.get('call:invite')({callId:'call_12345678', conversationId:'conversation123', calleeId:bob, callType:'video'});
  assert.ok(h.emitted.some(item => item.to === 'user:'+bob && item.event === 'call:incoming'));
  assert.ok(h.service.activeCalls.has('call_12345678'));
});

test('rejects attempts to call a user outside the conversation', async () => {
  const h = harness();
  await h.handlers.get('call:invite')({callId:'call_12345678', conversationId:'conversation123', calleeId:'mallory123456789012345678', callType:'audio'});
  assert.ok(h.emitted.some(item => item.event === 'call:error'));
  assert.equal(h.service.activeCalls.size, 0);
});

test('does not signal a user who has blocked the caller', async () => {
  const h = harness({blocked:['bob']});
  await h.handlers.get('call:invite')({callId:'call_12345678', conversationId:'conversation123', calleeId:bob, callType:'audio'});
  assert.ok(h.emitted.some(item => item.event === 'call:error'));
  assert.equal(h.service.activeCalls.size, 0);
});

test('only participants in an active call can relay WebRTC signals', async () => {
  const h = harness();
  await h.handlers.get('call:invite')({callId:'call_12345678', conversationId:'conversation123', calleeId:bob, callType:'audio'});
  h.handlers.get('call:signal')({callId:'call_12345678', signalType:'offer', signal:{sdp:'offer-sdp'}});
  assert.ok(h.emitted.some(item => item.to === 'user:'+bob && item.event === 'call:signal'));
  h.handlers.get('call:signal')({callId:'unknown_12345678', signalType:'offer', signal:{sdp:'spoof'}});
  assert.equal(h.emitted.filter(item => item.event === 'call:signal').length, 1);
});

test('call cancellation cleans up active state', async () => {
  const h = harness();
  await h.handlers.get('call:invite')({callId:'call_12345678', conversationId:'conversation123', calleeId:bob, callType:'audio'});
  h.handlers.get('call:cancel')({callId:'call_12345678'});
  assert.equal(h.service.activeCalls.size, 0);
  assert.ok(h.emitted.some(item => item.to === 'user:'+bob && item.event === 'call:cancel'));
});
