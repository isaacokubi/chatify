import test from 'node:test';
import assert from 'node:assert/strict';
import { processDarajaCallback } from './daraja-callback.js';

const callback = (overrides = {}) => ({
  CheckoutRequestID: 'ws_CO_123',
  MerchantRequestID: 'ws_MR_123',
  ResultCode: 0,
  ResultDesc: 'The service request is processed successfully.',
  CallbackMetadata: { Item: [
    { Name: 'Amount', Value: 500 },
    { Name: 'MpesaReceiptNumber', Value: 'QAB12CD34E' },
    { Name: 'PhoneNumber', Value: 254712345678 },
  ] },
  ...overrides,
});
const payment = {
  _id: 'db-payment-1',
  paymentId: 'payment-1',
  checkoutRequestId: 'ws_CO_123',
  merchantRequestId: 'ws_MR_123',
  status: 'PENDING',
  callbackProcessedAt: undefined,
  amount: 500,
  phone: '254712345678',
};

function harness({ pending = payment, existing = null, transitioned = { ...payment, status: 'SUCCESS' } } = {}) {
  const calls = { pending: 0, existing: 0, transition: 0 };
  return {
    calls,
    run: body => processDarajaCallback({
      callback: body,
      findPending: async refs => { calls.pending++; assert.equal(refs.checkoutRequestId, 'ws_CO_123'); return pending; },
      findExisting: async () => { calls.existing++; return existing; },
      transition: async ({ references, outcome }) => {
        calls.transition++;
        assert.equal(references.merchantRequestId, 'ws_MR_123');
        assert.equal(outcome.status, 'SUCCESS');
        return transitioned;
      },
    }),
  };
}

test('valid success callback transitions a matching payment exactly once', async () => {
  const h = harness();
  const result = await h.run(callback());
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.duplicate, false);
  assert.equal(result.body.payment.status, 'SUCCESS');
  assert.equal(h.calls.transition, 1);
});

test('malformed callback references are rejected before database lookups', async () => {
  const h = harness();
  const result = await h.run(callback({ CheckoutRequestID: '' }));
  assert.equal(result.statusCode, 400);
  assert.equal(h.calls.pending, 0);
  assert.equal(h.calls.transition, 0);
});

test('invalid successful callback amount/phone/receipt cannot transition payment', async () => {
  for (const invalid of [
    callback({ CallbackMetadata: { Item: [{ Name: 'Amount', Value: 1 }, { Name: 'MpesaReceiptNumber', Value: 'QAB12CD34E' }, { Name: 'PhoneNumber', Value: 254712345678 }] } }),
    callback({ CallbackMetadata: { Item: [{ Name: 'Amount', Value: 500 }, { Name: 'MpesaReceiptNumber', Value: 'QAB12CD34E' }, { Name: 'PhoneNumber', Value: 254700000000 }] } }),
    callback({ CallbackMetadata: { Item: [{ Name: 'Amount', Value: 500 }, { Name: 'PhoneNumber', Value: 254712345678 }] } }),
  ]) {
    const h = harness();
    const result = await h.run(invalid);
    assert.equal(result.statusCode, 400);
    assert.equal(h.calls.transition, 0);
  }
});

test('malformed result code is rejected without changing payment state', async () => {
  const h = harness();
  const result = await h.run(callback({ ResultCode: 'not-a-number' }));
  assert.equal(result.statusCode, 400);
  assert.equal(h.calls.transition, 0);
});

test('duplicate callback for an already completed payment is acknowledged without reapplying it', async () => {
  const h = harness({ pending: null, existing: { ...payment, status: 'SUCCESS' } });
  const result = await h.run(callback());
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.duplicate, true);
  assert.equal(h.calls.transition, 0);
});

test('concurrent duplicate callback that loses the atomic transition is acknowledged as duplicate', async () => {
  const h = harness({ transitioned: null, existing: { ...payment, status: 'SUCCESS' } });
  const result = await h.run(callback());
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.duplicate, true);
  assert.equal(h.calls.transition, 1);
});

test('a failed or cancelled callback can transition only through the same pending guard', async () => {
  for (const resultCode of [1032, 1]) {
    const h = harness({ transitioned: { ...payment, status: resultCode === 1032 ? 'CANCELLED' : 'FAILED' } });
    const result = await h.run(callback({ ResultCode: resultCode, CallbackMetadata: undefined }));
    assert.equal(result.statusCode, 200);
    assert.equal(result.body.duplicate, false);
    assert.equal(result.body.payment.status, resultCode === 1032 ? 'CANCELLED' : 'FAILED');
  }
});
