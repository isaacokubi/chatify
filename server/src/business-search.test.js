import test from 'node:test';
import assert from 'node:assert/strict';
import {escapeSearchRegex, normalizeBusinessSearchQuery} from './business-search.js';

test('business search normalizes whitespace and caps query length', () => {
  assert.equal(normalizeBusinessSearchQuery('  unpaid   office chairs  '), 'unpaid office chairs');
  assert.equal(normalizeBusinessSearchQuery('x'.repeat(150)).length, 100);
  assert.equal(normalizeBusinessSearchQuery(null), '');
});

test('business search treats user input as literal text, not a regular expression', () => {
  const regex = new RegExp(escapeSearchRegex('chair (15)+'), 'i');
  assert.equal(regex.test('Order for chair (15)+'), true);
  assert.equal(regex.test('Order for chair 15555'), false);
});
