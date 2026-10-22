import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeGroupDetails, normalizeGroupMemberIds, canLeaveGroup} from './groups.js';

test('group details are trimmed and bounded', () => {
  assert.deepEqual(normalizeGroupDetails({title: '  Project team ', description: '  Weekly updates  '}), {
    title: 'Project team', description: 'Weekly updates',
  });
  assert.equal(normalizeGroupDetails({title: '  '}), null);
  assert.equal(normalizeGroupDetails({title: 'x'.repeat(81)}), null);
  assert.equal(normalizeGroupDetails({title: 'Group', description: 'x'.repeat(501)}), null);
});

test('group membership is deduplicated and limited to 50 people', () => {
  assert.deepEqual(normalizeGroupMemberIds(['member-1', 'member-1'], 'owner'), ['owner', 'member-1']);
  assert.equal(normalizeGroupMemberIds([], 'owner'), null);
  assert.equal(normalizeGroupMemberIds(Array.from({length: 50}, (_, index) => `member-${index}`), 'owner'), null);
});

test('the last group administrator must promote another administrator before leaving', () => {
  assert.equal(canLeaveGroup('owner', ['owner'], ['owner', 'member']), false);
  assert.equal(canLeaveGroup('owner', ['owner', 'admin'], ['owner', 'admin', 'member']), true);
  assert.equal(canLeaveGroup('member', ['owner'], ['owner', 'member']), true);
});
