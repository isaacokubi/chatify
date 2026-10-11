import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveMpesaProvider} from './payments.js';

test('production can explicitly use the clearly labelled mock provider for a demo', () => {
  const provider = resolveMpesaProvider({NODE_ENV: 'production', MPESA_ENV: 'mock'});
  assert.equal(provider.name, 'mock');
  assert.equal(provider.isMock, true);
});

test('production fails clearly when MPESA_ENV is not explicitly configured', () => {
  assert.throws(
    () => resolveMpesaProvider({NODE_ENV: 'production'}),
    /explicit MPESA_ENV=mock for a demo or MPESA_ENV=production for live Daraja payments/,
  );
});

test('production refuses to use the Daraja sandbox', () => {
  assert.throws(
    () => resolveMpesaProvider({NODE_ENV: 'production', MPESA_ENV: 'sandbox'}),
    /MPESA_ENV=sandbox is not allowed in production/,
  );
});

test('live Daraja mode still requires its credentials and callback URL', () => {
  assert.throws(
    () => resolveMpesaProvider({NODE_ENV: 'production', MPESA_ENV: 'production'}),
    /Daraja credentials and callback URL are required/,
  );
});
