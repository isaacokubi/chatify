import test from 'node:test';
import assert from 'node:assert/strict';
import {sanitizeBusinessOrganization} from './business.js';

test('organization API serialization removes encrypted POS credentials and billing receipts', () => {
  const input = {
    _id: 'org-1',
    name: 'Example Shop',
    settings: {storefrontPublished: true, posDarajaCredentialsEncrypted: 'ciphertext'},
    billing: {billingEnforced: true, setupFeePaid: true, appliedPaymentIds: ['payment-internal-1']},
  };
  const output = sanitizeBusinessOrganization(input);
  assert.equal(output.settings.storefrontPublished, true);
  assert.equal(Object.hasOwn(output.settings, 'posDarajaCredentialsEncrypted'), false);
  assert.equal(output.billing.billingEnforced, true);
  assert.equal(Object.hasOwn(output.billing, 'appliedPaymentIds'), false);
  assert.equal(input.settings.posDarajaCredentialsEncrypted, 'ciphertext');
  assert.deepEqual(input.billing.appliedPaymentIds, ['payment-internal-1']);
});

test('organization API serialization handles mongoose-style documents', () => {
  const output = sanitizeBusinessOrganization({
    toObject: () => ({
      name: 'School Store',
      settings: {posDarajaCredentialsEncrypted: 'secret'},
      billing: {appliedPaymentIds: ['internal']},
    }),
  });
  assert.equal(output.name, 'School Store');
  assert.deepEqual(output.settings, {});
  assert.deepEqual(output.billing, {});
});
