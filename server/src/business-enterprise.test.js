import test from 'node:test';
import assert from 'node:assert/strict';
import {extractPromiseSuggestions, normalizeEnterpriseRecord} from './business-enterprise.js';

test('enterprise record validation uses allow-listed types and safe defaults', () => {
  const record = normalizeEnterpriseRecord({type: 'handbook', title: 'Staff handbook', priority: 'urgent', payload: {version: 2}});
  assert.equal(record.type, 'handbook');
  assert.equal(record.title, 'Staff handbook');
  assert.equal(record.status, 'open');
  assert.equal(record.priority, 'urgent');
  assert.deepEqual(record.payload, {version: 2});
});

test('enterprise record validation rejects missing titles and unknown types', () => {
  assert.throws(() => normalizeEnterpriseRecord({type: 'handbook', title: '  '}), /title is required/i);
  assert.throws(() => normalizeEnterpriseRecord({type: 'made_up', title: 'A record'}), /unsupported business record type/i);
  assert.throws(() => normalizeEnterpriseRecord({type: 'approval', title: 'Review', dueAt: 'not-a-date'}), /invalid due date/i);
});

test('promise extraction only returns unconfirmed suggestions from explicit wording', () => {
  const suggestions = extractPromiseSuggestions("I'll deliver the order by Friday. We will call the customer tomorrow.");
  assert.ok(suggestions.length >= 1);
  assert.ok(suggestions.every(item => item.confirmed === false));
  assert.ok(suggestions.every(item => item.notice.includes('Confirm')));
});

test('promise extraction handles empty and oversized input safely', () => {
  assert.deepEqual(extractPromiseSuggestions(''), []);
  assert.ok(extractPromiseSuggestions('x'.repeat(6000)).length <= 10);
});
