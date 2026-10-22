import test from 'node:test';
import assert from 'node:assert/strict';
import { validateClientMutationId } from './message-idempotency.js';

test('message mutation IDs accept URL-safe stable identifiers', () => {
  assert.deepEqual(validateClientMutationId('0123456789abcdef_XYZ'), { value: '0123456789abcdef_XYZ' });
});

test('message mutation IDs may be omitted by older clients', () => {
  assert.deepEqual(validateClientMutationId(undefined), { value: null });
  assert.deepEqual(validateClientMutationId(''), { value: null });
});

test('message mutation IDs reject short, oversized and unsafe identifiers', () => {
  assert.ok(validateClientMutationId('short').error);
  assert.ok(validateClientMutationId('x'.repeat(101)).error);
  assert.ok(validateClientMutationId('bad id with spaces').error);
});
