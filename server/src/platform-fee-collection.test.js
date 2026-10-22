import test from 'node:test';
import assert from 'node:assert/strict';
import mongoose from 'mongoose';
import {createPlatformFeeCollector} from './platform-fee-collection.js';

test('legacy platform fee collection is disabled even when no fee settings are present', async () => {
  const collector = createPlatformFeeCollector({mongoose, env: {}});
  const result = await collector.collect({
    paymentId: 'commission-free-test',
    source: 'business_checkout',
    payerPhone: '254712345678',
    baseAmount: 1000,
  });
  assert.deepEqual(result, {
    paymentId: 'commission-free-test',
    source: 'business_checkout',
    status: 'NOT_APPLICABLE',
    feeAmount: 0,
    baseAmount: 1000,
  });
});

test('legacy platform fee collection cannot be re-enabled by environment flags', async () => {
  const collector = createPlatformFeeCollector({mongoose, env: {ENABLE_LEGACY_PLATFORM_FEES: 'true'}});
  const result = await collector.collect({
    paymentId: 'commission-free-test-2',
    source: 'school_fee',
    payerPhone: '254712345678',
    baseAmount: 2500,
  });
  assert.equal(result.status, 'NOT_APPLICABLE');
  assert.equal(result.feeAmount, 0);
});
