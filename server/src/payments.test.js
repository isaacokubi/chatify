import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveMpesaProvider, canCancelPayment} from './payments.js';

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

test('either participant can reject a pending request before STK initiation', () => {
  const payment = {requesterId:'requester', payerId:'payer', status:'PENDING'};
  assert.equal(canCancelPayment(payment, 'requester'), true);
  assert.equal(canCancelPayment(payment, 'payer'), true);
});

test('only participants can reject a pending request', () => {
  const payment = {requesterId:'requester', payerId:'payer', status:'PENDING'};
  assert.equal(canCancelPayment(payment, 'stranger'), false);
  assert.equal(canCancelPayment(payment, 'payer', false), false);
});

test('a request cannot be rejected once STK initiation has started or finished', () => {
  assert.equal(canCancelPayment({requesterId:'r', payerId:'p', status:'PENDING', initiating:true}, 'p'), false);
  assert.equal(canCancelPayment({requesterId:'r', payerId:'p', status:'PENDING', initiatedAt:new Date()}, 'p'), false);
});

test('a terminal payment cannot be rejected', () => {
  assert.equal(canCancelPayment({requesterId:'r', payerId:'p', status:'SUCCESS'}, 'p'), false);
  assert.equal(canCancelPayment({requesterId:'r', payerId:'p', status:'CANCELLED'}, 'r'), false);
});
