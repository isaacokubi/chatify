import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveMpesaProvider, canCancelPayment, resolveCallbackOutcome, canTransitionPayment, calculatePlatformFee, calculatePaymentTotal} from './payments.js';

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
  const payment = {requesterId:'requester', payerId:'payer', conversationId:'conversation', status:'PENDING'};
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

test('Daraja provider reports OAuth transport failures without leaking secrets', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const provider = createDarajaProvider({
    mode: 'sandbox', consumerKey: 'test-key', consumerSecret: 'test-secret',
    shortcode: '123456', passkey: 'test-passkey',
    callbackUrl: 'https://api.example.org/api/payments/daraja/callback',
  }, async () => { throw new Error('socket failure'); });
  await assert.rejects(
    provider.initiate({paymentId:'test-payment', amount:10, phone:'254712345678', description:'Test'}),
    error => error.stage === 'oauth_transport' && /OAuth network request failed/.test(error.message),
  );
});

test('Daraja provider distinguishes a rejected STK request from transport failures', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const provider = createDarajaProvider({
    mode: 'sandbox', consumerKey: 'test-key', consumerSecret: 'test-secret',
    shortcode: '123456', passkey: 'test-passkey',
    callbackUrl: 'https://api.example.org/api/payments/daraja/callback',
  }, async url => url.includes('/oauth/')
    ? {ok:true, json:async()=>({access_token:'test-token',expires_in:3600})}
    : {ok:false, json:async()=>({ResponseCode:'1',errorMessage:'rejected'})});
  await assert.rejects(
    provider.initiate({paymentId:'test-payment', amount:10, phone:'254712345678', description:'Test'}),
    error => error.stage === 'stk_rejected' && /rejected the STK request/.test(error.message),
  );
});

test('Daraja Dynamic QR requests a real M-Pesa QR for a merchant shortcode', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const requests = [];
  const provider = createDarajaProvider({
    mode: 'sandbox', consumerKey: 'test-key', consumerSecret: 'test-secret',
    shortcode: '123456', passkey: 'test-passkey',
    callbackUrl: 'https://api.example.org/api/payments/daraja/callback',
  }, async (url, options = {}) => {
    requests.push({url, options});
    return url.includes('/oauth/')
      ? {ok: true, json: async () => ({access_token: 'test-token', expires_in: 3600})}
      : {ok: true, json: async () => ({ResponseCode: 'AG_OK', RequestID: 'request-1', QRCode: 'iVBORw0KGgoAAAAAAAAAAAAAAAAA'})};
  });
  const result = await provider.generateDynamicQr({
    merchantName: 'A Very Long Supermarket Name That Must Be Cut', reference: 'REFERENCE-123456789', amount: 450,
    shortcode: '1234567', transactionCode: 'BG',
  });
  assert.equal(result.qrCode, 'iVBORw0KGgoAAAAAAAAAAAAAAAAA');
  assert.equal(result.requestId, 'request-1');
  const body = JSON.parse(requests[1].options.body);
  assert.equal(requests[1].url, 'https://sandbox.safaricom.co.ke/mpesa/qrcode/v1/generate');
  assert.equal(body.MerchantName, 'A Very Long Supermar');
  assert.equal(body.RefNo, 'REFERENCE-12'); // Safaricom RefNo is limited to 12 characters.
  assert.ok(body.MerchantName.length <= 20);
  assert.ok(body.RefNo.length <= 12);
  assert.equal(body.Amount, 450);
  assert.equal(body.TrxCode, 'BG');
  assert.equal(body.CPI, '1234567');
});

test('Dynamic QR rejects invalid merchant shortcodes before calling Daraja', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const provider = createDarajaProvider({
    mode: 'sandbox', consumerKey: 'test-key', consumerSecret: 'test-secret',
    shortcode: '123456', passkey: 'test-passkey',
    callbackUrl: 'https://api.example.org/api/payments/daraja/callback',
  }, async () => { throw new Error('should not be called'); });
  await assert.rejects(provider.generateDynamicQr({
    merchantName: 'Shop', reference: 'SALE-1', amount: 450,
    shortcode: 'not-a-till', transactionCode: 'BG',
  }), error => error.stage === 'qr_validation');
});

test('Daraja STK request respects AccountReference and TransactionDesc length limits', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const requests = [];
  const provider = createDarajaProvider({
    mode: 'sandbox', consumerKey: 'test-key', consumerSecret: 'test-secret',
    shortcode: '123456', passkey: 'test-passkey',
    callbackUrl: 'https://api.example.org/api/payments/daraja/callback',
  }, async (url, options = {}) => {
    requests.push({url, options});
    return url.includes('/oauth/')
      ? {ok: true, json: async () => ({access_token: 'test-token', expires_in: 3600})}
      : {ok: true, json: async () => ({
          ResponseCode: '0', CheckoutRequestID: 'checkout-1', MerchantRequestID: 'merchant-1',
        })};
  });
  await provider.initiate({
    paymentId: '12345678-1234-1234-1234-123456789abc',
    amount: 250,
    phone: '254712345678',
    description: 'A payment description that is longer than allowed',
  });
  const body = JSON.parse(requests[1].options.body);
  assert.equal(body.AccountReference, '123456789abc');
  assert.equal(body.TransactionDesc, 'A payment des');
  assert.ok(body.AccountReference.length <= 12);
  assert.ok(body.TransactionDesc.length <= 13);
});


test('M-Pesa success callbacks must match the original amount and phone', () => {
  const payment = {amount: 450, phone: '254712345678'};
  const callback = {ResultCode: 0, ResultDesc: 'Success', CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 450}, {Name: 'PhoneNumber', Value: 254712345678},
  ]}};
  assert.equal(resolveCallbackOutcome(callback, payment).status, 'SUCCESS');
  assert.equal(resolveCallbackOutcome({...callback, CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 451}, {Name: 'PhoneNumber', Value: 254712345678},
  ]}}, payment).error, 'mismatch');
  assert.equal(resolveCallbackOutcome({...callback, CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 450}, {Name: 'PhoneNumber', Value: 254700000000},
  ]}}, payment).error, 'mismatch');
});

test('M-Pesa callbacks reject malformed results and classify cancellation/failure', () => {
  const payment = {amount: 450, phone: '254712345678'};
  assert.equal(resolveCallbackOutcome({ResultCode: 'bad'}, payment).error, 'malformed');
  assert.equal(resolveCallbackOutcome({ResultCode: 1032}, payment).status, 'CANCELLED');
  assert.equal(resolveCallbackOutcome({ResultCode: 1, ResultDesc: 'Failed'}, payment).status, 'FAILED');
});

test('payment state transitions are one-time and reject already processed callbacks', () => {
  assert.equal(canTransitionPayment('PENDING', undefined), true);
  assert.equal(canTransitionPayment('PENDING', new Date()), false);
  assert.equal(canTransitionPayment('SUCCESS', undefined), false);
});


test('payment totals are commission-free by default', () => {
  assert.deepEqual(calculatePaymentTotal(1000), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
  assert.deepEqual(calculatePaymentTotal(150000), {
    baseAmount:150000, platformFee:0, totalAmount:150000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('legacy fee calculation is available only when explicitly requested by a caller', () => {
  assert.equal(calculatePlatformFee(1000), 5);
  assert.equal(calculatePlatformFee(450), 3);
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:true}), {
    baseAmount:1000, platformFee:5, totalAmount:1005, platformFeeRate:0.5, platformFeeStatus:'PENDING_PAYMENT'
  });
  assert.throws(() => calculatePaymentTotal(150000, {applicable:true}), /must not exceed KSh 150000/);
});

test('ordinary user-to-user transfers do not receive a Chatify platform fee', () => {
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:false}), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('eligible business payments respect the administrator-configured fee rate', () => {
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:true, feeRate:0.25}), {
    baseAmount:1000, platformFee:3, totalAmount:1003, platformFeeRate:0.25, platformFeeStatus:'PENDING_PAYMENT'
  });
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:true, feeRate:0}), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('merchant payment callback matches the base amount while the platform fee is collected separately', () => {
  const payment = {amount:1000, baseAmount:1000, totalAmount:1005, feeCollectionMode:'separate', phone:'254712345678'};
  const callback = {ResultCode:0, ResultDesc:'Success', CallbackMetadata:{Item:[
    {Name:'Amount',Value:1000}, {Name:'PhoneNumber',Value:254712345678},
  ]}};
  assert.equal(resolveCallbackOutcome(callback,payment).status,'SUCCESS');
  assert.equal(resolveCallbackOutcome({...callback,CallbackMetadata:{Item:[
    {Name:'Amount',Value:1005}, {Name:'PhoneNumber',Value:254712345678},
  ]}},payment).error,'mismatch');
});
