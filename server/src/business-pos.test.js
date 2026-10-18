import test from 'node:test';
import assert from 'node:assert/strict';
import {buildPosCharge, canUsePosRole, normalizeMerchantPaymentProfile} from './business-pos.js';

test('validates Till profile and creates a customer-readable payment QR payload', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_till', tillNumber: '1234567'});
  const charge = buildPosCharge({organization: {_id: 'org-1', name: 'Sample Supermarket'}, amount: 450, description: 'Groceries', reference: 'SALE-1', profile});
  const qr = JSON.parse(charge.qrPayload);
  assert.equal(charge.status, 'PENDING');
  assert.equal(qr.amount, 450);
  assert.equal(qr.paymentId, charge.paymentId);
  assert.equal(qr.description, 'Groceries');
  assert.equal(qr.tillNumber, '1234567');
  assert.equal(qr.merchantName, 'Sample Supermarket');
});

test('Paybill requires account reference and validates amount', () => {
  assert.throws(() => normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456'}), /account\/reference/);
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456', accountNumber: 'INV-42'});
  assert.throws(() => buildPosCharge({organization: {_id: 'x', name: 'Hotel'}, amount: 1.5, description: 'Room', profile}), /whole number/);
});

test('POS permissions include sales and finance but exclude read-only viewers', () => {
  assert.equal(canUsePosRole('sales'), true);
  assert.equal(canUsePosRole('finance'), true);
  assert.equal(canUsePosRole('viewer'), false);
});
