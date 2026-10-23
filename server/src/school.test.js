import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSchoolPaymentProfile, encryptSchoolSecret, decryptSchoolSecret, resolveSchoolMessageDestination, schoolPaymentMethodLabel } from './school.js';
import { createEmailProvider } from './providers.js';

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

test('school payment method labels cover supported methods and leave unknown legacy data unresolved', () => {
  assert.deepEqual([
    schoolPaymentMethodLabel('mpesa_paybill'),
    schoolPaymentMethodLabel('mpesa_till'),
    schoolPaymentMethodLabel('mpesa_send_money'),
    schoolPaymentMethodLabel('bank'),
  ], ['M-Pesa Paybill', 'M-Pesa Till', 'M-Pesa Send Money', 'Bank transfer']);
  assert.equal(schoolPaymentMethodLabel(undefined), null);
  assert.equal(schoolPaymentMethodLabel('cash'), null);
});

test('encrypts school Daraja secrets and only decrypts with the correct key', () => {
  const key = 'test-only-school-payment-encryption-key';
  const encrypted = encryptSchoolSecret('daraja-secret-value', key);
  assert.notEqual(encrypted, 'daraja-secret-value');
  assert.equal(decryptSchoolSecret(encrypted, key), 'daraja-secret-value');
  assert.throws(() => decryptSchoolSecret(encrypted, 'another-test-encryption-key-that-is-long-enough'), /Unsupported state|authenticate|tag/i);
});

test('refuses to encrypt school payment credentials without a strong configured key', () => {
  assert.throws(() => encryptSchoolSecret('secret', 'short'), /encryption/i);
});


test('school receipt emails can be delivered through the configured email transport', async () => {
  const sent = [];
  const email = createEmailProvider({ from: 'receipts@example.test', production: true }, {
    async sendSchoolFeeReceipt(payload) { sent.push(payload); return { sent: true }; },
  });
  assert.equal(email.available, true);
  const result = await email.sendSchoolFeeReceipt({
    email: 'parent@example.test', schoolName: 'Example School', paymentReference: 'SCH-123456789ABC',
    receiptNumber: 'QAB123XYZ', amount: 25000, studentName: 'Student One', term: 'Term 1',
    receiptHtml: '<html>official receipt</html>',
  });
  assert.deepEqual(result, { sent: true });
  assert.equal(sent.length, 1);
  assert.equal(sent[0].email, 'parent@example.test');
  assert.match(sent[0].receiptHtml, /official receipt/);
});

test('parents and staff can only address messages to their school inbox', () => {
  assert.deepEqual(resolveSchoolMessageDestination('parent', 'school_inbox', undefined), { audience: 'school_inbox', recipientId: undefined });
  assert.deepEqual(resolveSchoolMessageDestination('staff', 'school_inbox', undefined), { audience: 'school_inbox', recipientId: undefined });
  assert.match(resolveSchoolMessageDestination('parent', 'direct', 'platform-admin-id').error, /school inbox/i);
  assert.match(resolveSchoolMessageDestination('staff', 'direct', 'platform-admin-id').error, /school inbox/i);
  assert.match(resolveSchoolMessageDestination('parent', 'school_inbox', 'platform-admin-id').error, /school inbox/i);
});

test('school administrators retain supported direct and announcement destinations', () => {
  assert.deepEqual(resolveSchoolMessageDestination('admin', 'direct', 'school-staff-id'), { audience: 'direct', recipientId: 'school-staff-id' });
  assert.deepEqual(resolveSchoolMessageDestination('admin', 'all_school', undefined), { audience: 'all_school', recipientId: undefined });
});
