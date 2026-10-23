import test from 'node:test';
import assert from 'node:assert/strict';
import {createPresenceTracker} from './presence.js';

test('presence stays online until the final authenticated socket disconnects', () => {
  const presence = createPresenceTracker();
  assert.equal(presence.connect('user-1', 'phone'), true);
  assert.equal(presence.connect('user-1', 'browser'), false);
  assert.equal(presence.isOnline('user-1'), true);
  assert.equal(presence.disconnect('user-1', 'phone'), false);
  assert.equal(presence.isOnline('user-1'), true);
  assert.equal(presence.disconnect('user-1', 'browser'), true);
  assert.equal(presence.isOnline('user-1'), false);
});

test('duplicate disconnects and reconnects do not corrupt session presence', () => {
  const presence = createPresenceTracker();
  presence.connect('user-1', 'socket-1');
  assert.equal(presence.disconnect('user-1', 'socket-1'), true);
  assert.equal(presence.disconnect('user-1', 'socket-1'), false);
  assert.equal(presence.connect('user-1', 'socket-2'), true);
  assert.deepEqual(presence.onlineUserIds(), ['user-1']);
  assert.equal(presence.disconnect('user-1', 'stale-socket'), false);
  assert.equal(presence.isOnline('user-1'), true);
});
