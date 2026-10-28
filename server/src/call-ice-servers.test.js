import test from 'node:test';
import assert from 'node:assert/strict';
import {buildCallIceServers} from './call-ice-servers.js';

test('returns STUN-only configuration when TURN is not configured', () => {
  const result = buildCallIceServers({userId:'user123', now:1000000});
  assert.equal(result.turnConfigured, false);
  assert.equal(result.iceServers.length, 1);
  assert.equal(result.iceServers[0].urls, 'stun:stun.l.google.com:19302');
});

test('creates short-lived TURN credentials without exposing the shared secret', () => {
  const secret = 'a'.repeat(40);
  const result = buildCallIceServers({
    userId:'user123',
    turnUrls:'turn:turn.example.test:3478?transport=udp, turns:turn.example.test:5349',
    sharedSecret:secret,
    now:1000000,
    ttlSeconds:120,
  });
  assert.equal(result.turnConfigured, true);
  assert.equal(result.iceServers.length, 2);
  assert.deepEqual(result.iceServers[1].urls, ['turn:turn.example.test:3478?transport=udp', 'turns:turn.example.test:5349']);
  assert.equal(result.iceServers[1].username, '1120:user123');
  assert.notEqual(result.iceServers[1].credential, secret);
  assert.equal(result.expiresAt, new Date(1120000).toISOString());
});

test('ignores invalid URL schemes and refuses weak shared secrets', () => {
  const result = buildCallIceServers({userId:'user123',turnUrls:'https://invalid.test',sharedSecret:'short'});
  assert.equal(result.turnConfigured, false);
  assert.equal(result.iceServers.length, 1);
});
