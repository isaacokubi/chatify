import test from 'node:test';
import assert from 'node:assert/strict';
import {MAX_NOTIFICATION_ATTEMPTS,notificationRetryDelayMs,notificationExpiryDate} from './notification-queue.js';

test('notification retries back off and remain capped',()=>{
  assert.equal(notificationRetryDelayMs(1),2000);
  assert.equal(notificationRetryDelayMs(8),300000);
  assert.equal(notificationRetryDelayMs(99),300000);
  assert.equal(MAX_NOTIFICATION_ATTEMPTS,8);
});

test('notification metadata expires thirty days after completion',()=>{
  const now=new Date('2026-10-20T00:00:00.000Z');
  assert.equal(notificationExpiryDate(now).toISOString(),'2026-11-19T00:00:00.000Z');
});
