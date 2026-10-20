import test from 'node:test';
import assert from 'node:assert/strict';
import {buildPosCharge, canUsePosRole, normalizeMerchantPaymentProfile, encryptMerchantCredentials, decryptMerchantCredentials, validateMerchantDarajaCredentials, resolvePosStkCallbackOutcome} from './business-pos.js';

test('validates Till profile and creates a customer-readable payment QR payload', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_till', tillNumber: '1234567'});
  const charge = buildPosCharge({organization: {_id: 'org-1', name: 'Sample Supermarket'}, amount: 450, description: 'Groceries', reference: 'SALE-1', profile});
  const qr = JSON.parse(charge.qrPayload);
  assert.equal(charge.status, 'PENDING');
  assert.equal(qr.amount, 453);
  assert.equal(charge.baseAmount, 450);
  assert.equal(charge.platformFee, 3);
  assert.equal(charge.totalAmount, 453);
  assert.equal(charge.platformFeeStatus, 'PENDING_PAYMENT');
  assert.equal(qr.paymentId, charge.paymentId);
  assert.equal(qr.description, 'Groceries');
  assert.equal(qr.tillNumber, '1234567');
  assert.equal(charge.reference, 'SALE-1');
  assert.equal(qr.merchantName, 'Sample Supermarket');
});

test('Paybill profile can be configured without a fixed account number and validates amount', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456'});
  assert.throws(() => buildPosCharge({organization: {_id: 'x', name: 'Hotel'}, amount: 1.5, description: 'Room', profile}), /whole number/);
});

test('POS references are capped at Safaricom Dynamic QR RefNo limit', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456'});
  const charge = buildPosCharge({
    organization: {_id: 'org-ref', name: 'Reference Test'},
    amount: 100, description: 'Test sale', reference: 'REFERENCE-123456789', profile,
  });
  assert.equal(charge.reference, 'REFERENCE-12');
  assert.equal(charge.reference.length, 12);
  assert.equal(JSON.parse(charge.qrPayload).reference, charge.reference);
});

test('POS permissions include sales and finance but exclude read-only viewers', () => {
  assert.equal(canUsePosRole('sales'), true);
  assert.equal(canUsePosRole('finance'), true);
  assert.equal(canUsePosRole('viewer'), false);
});

test('Paybill sale gets its own safe reference for provider reconciliation', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456'});
  const charge = buildPosCharge({
    organization: {_id: 'org-2', name: 'City Hotel'},
    amount: 1800, description: 'Room deposit', reference: 'Room 204 / Oct',
    profile,
  });
  assert.equal(charge.reference, 'Room-204-Oct');
  assert.equal(charge.destination.paybillNumber, '123456');
  assert.equal(charge.destination.accountNumber, charge.reference);
  assert.equal(JSON.parse(charge.qrPayload).accountNumber, charge.reference);
});


test('merchant Daraja credentials are encrypted at rest and can be decrypted only with the key', () => {
  const key = Buffer.alloc(32, 7);
  const credentials = {mode: 'production', consumerKey: 'merchant-key', consumerSecret: 'merchant-secret', passkey: 'merchant-passkey', shortcode: '123456'};
  const encrypted = encryptMerchantCredentials(credentials, key);
  assert.equal(encrypted.includes('merchant-secret'), false);
  assert.deepEqual(decryptMerchantCredentials(encrypted, key), credentials);
  assert.throws(() => decryptMerchantCredentials(encrypted, Buffer.alloc(32, 8)));
});

test('merchant STK routing requires shortcode to match the configured merchant destination', () => {
  const till = normalizeMerchantPaymentProfile({method: 'mpesa_till', tillNumber: '1234567'});
  const credentials = {mode: 'production', consumerKey: 'key', consumerSecret: 'secret', passkey: 'passkey', shortcode: '1234567'};
  assert.deepEqual(validateMerchantDarajaCredentials(credentials, till), credentials);
  assert.throws(() => validateMerchantDarajaCredentials({...credentials, shortcode: '7654321'}, till), /exactly match/);
  assert.throws(() => validateMerchantDarajaCredentials({...credentials, mode: 'mock'}, till), /sandbox or production/);
});

test('merchant STK routing validates Paybill shortcode independently from Till numbers', () => {
  const paybill = normalizeMerchantPaymentProfile({method: 'mpesa_paybill', paybillNumber: '123456', accountNumber: 'INVOICE-1'});
  assert.equal(validateMerchantDarajaCredentials({mode: 'sandbox', consumerKey: 'key', consumerSecret: 'secret', passkey: 'passkey', shortcode: '123456'}, paybill).shortcode, '123456');
  assert.throws(() => validateMerchantDarajaCredentials({mode: 'sandbox', consumerKey: 'key', consumerSecret: 'secret', passkey: 'passkey', shortcode: '1234567'}, paybill), /exactly match/);
});


test('STK callback confirms only exact amount, normalized payer phone and receipt', () => {
  const charge = {amount: 450, stkPhone: '254712345678'};
  const callback = {ResultCode: 0, ResultDesc: 'Success', CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 450},
    {Name: 'PhoneNumber', Value: 254712345678},
    {Name: 'MpesaReceiptNumber', Value: 'QWERTY1234'},
  ]}};
  assert.deepEqual(resolvePosStkCallbackOutcome(callback, charge), {
    status: 'SUCCESS', resultCode: 0, phone: '254712345678', receipt: 'QWERTY1234', description: 'Success',
  });
  assert.equal(resolvePosStkCallbackOutcome({...callback, CallbackMetadata: {Item: [{Name: 'Amount', Value: 449}, {Name: 'PhoneNumber', Value: 254712345678}, {Name: 'MpesaReceiptNumber', Value: 'QWERTY1234'}]}}, charge).error, 'mismatch');
  assert.equal(resolvePosStkCallbackOutcome({...callback, CallbackMetadata: {Item: [{Name: 'Amount', Value: 450}, {Name: 'PhoneNumber', Value: 254700000000}, {Name: 'MpesaReceiptNumber', Value: 'QWERTY1234'}]}}, charge).error, 'mismatch');
});

test('STK callback maps user cancellation and provider failure without marking a sale paid', () => {
  const charge = {amount: 200, stkPhone: '254712345678'};
  assert.equal(resolvePosStkCallbackOutcome({ResultCode: 1032, ResultDesc: 'Request cancelled'}, charge).status, 'CANCELLED');
  assert.equal(resolvePosStkCallbackOutcome({ResultCode: 1, ResultDesc: 'Failed'}, charge).status, 'FAILED');
  assert.equal(resolvePosStkCallbackOutcome({ResultCode: 'invalid'}, charge).error, 'malformed');
});


test('business checkout adds the 0.5% fee on top and rejects totals above the provider cap', () => {
  const profile = normalizeMerchantPaymentProfile({method: 'mpesa_till', tillNumber: '1234567'});
  const charge = buildPosCharge({organization: {_id: 'org-fee', name: 'Fee Test'}, amount: 1000, description: 'Checkout', profile});
  assert.equal(charge.baseAmount, 1000);
  assert.equal(charge.platformFee, 5);
  assert.equal(charge.amount, 1000);
  assert.equal(charge.totalAmount, 1005);
  assert.equal(JSON.parse(charge.qrPayload).amount, 1000);
  assert.throws(() => buildPosCharge({organization: {_id: 'org-fee', name: 'Fee Test'}, amount: 150000, description: 'Checkout', profile}), /0.5% platform fee/);
});

test('POS STK validates the merchant base amount and leaves platform fee for separate collection', () => {
  const charge = {amount:450, baseAmount:450, totalAmount:453, platformFee:3, stkPhone:'254712345678'};
  const callback = {ResultCode:0, ResultDesc:'Success', CallbackMetadata:{Item:[
    {Name:'Amount',Value:450}, {Name:'PhoneNumber',Value:254712345678}, {Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}};
  assert.equal(resolvePosStkCallbackOutcome(callback,charge).status,'SUCCESS');
  assert.equal(resolvePosStkCallbackOutcome({...callback,CallbackMetadata:{Item:[{Name:'Amount',Value:453},{Name:'PhoneNumber',Value:254712345678},{Name:'MpesaReceiptNumber',Value:'QWERTY1234'}]}},charge).error,'mismatch');
});
