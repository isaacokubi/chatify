import test from 'node:test';
import assert from 'node:assert/strict';
import {buildServiceStatus} from './service-status.js';

test('public status reports database degradation without exposing configuration', () => {
  const result = buildServiceStatus({databaseReady: false, uptimeSeconds: 12.9, now: new Date('2026-01-02T03:04:05.000Z')});
  assert.equal(result.status, 'degraded');
  assert.equal(result.components.find(item => item.name === 'Database').status, 'degraded');
  assert.equal(result.uptimeSeconds, 12);
  assert.equal(result.checkedAt, '2026-01-02T03:04:05.000Z');
  assert.equal(JSON.stringify(result).includes('password'), false);
  assert.equal(JSON.stringify(result).includes('secret'), false);
});

test('public status does not falsely claim third-party providers are healthy', () => {
  const result = buildServiceStatus({databaseReady: true});
  assert.equal(result.status, 'operational');
  assert.equal(result.components.find(item => item.name === 'Payment providers').status, 'unverified');
});
