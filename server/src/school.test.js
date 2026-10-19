import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSchoolPaymentProfile } from './school.js';

test('accepts a valid school Paybill profile and removes spaces', () => {
  assert.deepEqual(normalizeSchoolPaymentProfile({ method: 'mpesa_paybill', paybillNumber: ' 123 456 ', accountNumber: 'STUDENT-001' }), {
    method: 'mpesa_paybill', paybillNumber: '123456', tillNumber: '', accountNumber: 'STUDENT-001', bankName: ''
  });
});

test('rejects invalid Paybill and Till details', () => {
  assert.throws(() => normalizeSchoolPaymentProfile({ method: 'mpesa_paybill', paybillNumber: 'ABC' }), /Paybill/);
  assert.throws(() => normalizeSchoolPaymentProfile({ method: 'mpesa_till', tillNumber: '123' }), /Till/);
});

test('requires both bank name and account number for bank transfer', () => {
  assert.throws(() => normalizeSchoolPaymentProfile({ method: 'bank', bankName: 'Example Bank' }), /bank name and account number/);
});

test('rejects unsupported payment methods', () => {
  assert.throws(() => normalizeSchoolPaymentProfile({ method: 'cash' }), /Choose M-Pesa/);
});
