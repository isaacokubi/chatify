import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeMpesaPhone,validPaymentAmount,calculatePlatformFee,calculatePaymentTotal,createMockMpesaProvider,createDarajaProvider,resolveMpesaProvider,resolveCallbackOutcome,canTransitionPayment,canAccessPayment,canRetryPayment} from '../src/payments.js';

test('validates whole KSh amounts and Kenyan Safaricom numbers', () => {
  assert.equal(validPaymentAmount(1), true);
  assert.equal(validPaymentAmount(150000), true);
  for (const value of [0, -1, 1.5, '100', Number.MAX_SAFE_INTEGER, 150001]) assert.equal(validPaymentAmount(value), false);
  assert.equal(normalizeMpesaPhone('0712 345 678'), '254712345678');
  assert.equal(normalizeMpesaPhone('0112 345 678'), '254112345678');
  assert.equal(normalizeMpesaPhone('+254 112 345 678'), '254112345678');
  for (const value of ['254012345678', '07123', '1234567890', '+1 555 123 4567', 254712345678]) assert.equal(normalizeMpesaPhone(value), null);
});

test('mock mode needs no Daraja credentials and clearly identifies itself', async () => {
  const provider = resolveMpesaProvider({NODE_ENV:'development'});
  assert.equal(provider.name, 'mock');
  assert.equal(provider.isMock, true);
  assert.match((await provider.initiate({paymentId:'payment-123'})).checkoutRequestId, /^MOCK-/);
  assert.throws(() => resolveMpesaProvider({NODE_ENV:'production'}), /explicit MPESA_ENV=mock for a demo or MPESA_ENV=production/);
  assert.throws(() => resolveMpesaProvider({NODE_ENV:'production',MPESA_ENV:'production'}), /credentials and callback URL/);
});

test('Daraja rejects loopback, private IP literals and reserved callback hosts', () => {
  for (const callbackUrl of ['http://public.example/callback','https://localhost/callback','https://127.0.0.1/callback','https://192.168.1.10/callback','https://chatify.internal/callback','https://demo.test/callback']) {
    assert.throws(()=>createDarajaProvider({mode:'sandbox',consumerKey:'key',consumerSecret:'secret',shortcode:'123456',passkey:'pass',callbackUrl}),/public HTTPS URL/);
  }
});

test('Daraja uses the sandbox host, timestamp password, timeout and STK request fields', async () => {
  const calls = [];
  const transport = async (url, options) => {
    calls.push({url, options});
    if (url.includes('/oauth/')) return new Response(JSON.stringify({access_token:'test-access',expires_in:'3600'}), {status:200});
    return new Response(JSON.stringify({ResponseCode:'0',CheckoutRequestID:'ws_CO_1',MerchantRequestID:'merchant_1'}), {status:200});
  };
  const provider = createDarajaProvider({mode:'sandbox',consumerKey:'key',consumerSecret:'secret',shortcode:'123456',passkey:'pass',callbackUrl:'https://chatify-test.example.com/callback'}, transport);
  const refs = await provider.initiate({paymentId:'12345678901234567890',amount:500,phone:'254712345678',description:'Lunch',now:new Date('2026-10-11T06:08:07Z')});
  assert.equal(provider.isMock, false);
  assert.deepEqual(refs,{checkoutRequestId:'ws_CO_1',merchantRequestId:'merchant_1'});
  assert.match(calls[0].url,/^https:\/\/sandbox\.safaricom\.co\.ke\/oauth\//);
  assert.match(calls[1].url,/^https:\/\/sandbox\.safaricom\.co\.ke\/mpesa\/stkpush\//);
  const body = JSON.parse(calls[1].options.body);
  assert.equal(body.Timestamp,'20261011090807');
  assert.equal(body.Password,Buffer.from('123456pass20261011090807').toString('base64'));
  assert.equal(body.Amount,500);
  assert.equal(body.PhoneNumber,'254712345678');
  assert.equal(calls[1].options.signal.aborted,false);
});

test('provider errors do not look like accepted payments', async () => {
  const failing = createDarajaProvider({mode:'sandbox',consumerKey:'key',consumerSecret:'secret',shortcode:'123456',passkey:'pass',callbackUrl:'https://chatify-test.example.com/callback'}, async () => new Response('{}',{status:401}));
  await assert.rejects(failing.initiate({amount:100,phone:'254712345678',description:'Test',paymentId:'abcdef'}), /authentication failed/);
});

test('callback outcomes verify successful amount and phone and map failure/cancellation', () => {
  const payment = {amount:500,phone:'254712345678'};
  const success = {ResultCode:0,ResultDesc:'Success',CallbackMetadata:{Item:[{Name:'Amount',Value:500},{Name:'PhoneNumber',Value:254712345678}]}};
  assert.equal(resolveCallbackOutcome(success,payment).status,'SUCCESS');
  assert.equal(resolveCallbackOutcome({...success,CallbackMetadata:{Item:[{Name:'Amount',Value:100},{Name:'PhoneNumber',Value:254712345678}]}},payment).error,'mismatch');
  assert.equal(resolveCallbackOutcome({ResultCode:1032,ResultDesc:'Cancelled'},payment).status,'CANCELLED');
  assert.equal(resolveCallbackOutcome({ResultCode:1,ResultDesc:'Rejected'},payment).status,'FAILED');
  assert.equal(resolveCallbackOutcome({},payment).error,'malformed');
  assert.equal(resolveCallbackOutcome({ResultCode:null},payment).error,'malformed');
});

test('callback validates the buyer-paid total including the platform fee', () => {
  const payment = {amount: 1000, totalAmount: 1005, phone: '254712345678'};
  const success = {ResultCode: 0, ResultDesc: 'Success', CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 1005}, {Name: 'PhoneNumber', Value: 254712345678},
  ]}};
  assert.equal(resolveCallbackOutcome(success, payment).status, 'SUCCESS');
  assert.equal(resolveCallbackOutcome({...success, CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 1000}, {Name: 'PhoneNumber', Value: 254712345678},
  ]}}, payment).error, 'mismatch');
});

test('callback transition is idempotent after a result is recorded', () => {
  assert.equal(canTransitionPayment('PENDING',undefined),true);
  assert.equal(canTransitionPayment('SUCCESS',new Date()),false);
  assert.equal(canTransitionPayment('PENDING',new Date()),false);
});

test('payment reads require a requester or payer and current conversation membership', () => {
  const payment = {requesterId:'alice',payerId:'brian',conversationId:'thread'};
  assert.equal(canAccessPayment(payment,'alice',true),true);
  assert.equal(canAccessPayment(payment,'brian',true),true);
  assert.equal(canAccessPayment(payment,'mallory',true),false);
  assert.equal(canAccessPayment(payment,'alice',false),false);
  assert.equal(canRetryPayment({...payment,status:'FAILED'},'brian',true),true);
  assert.equal(canRetryPayment({...payment,status:'SUCCESS'},'brian',true),false);
  assert.equal(canRetryPayment({...payment,status:'FAILED'},'alice',true),false);
});


test('platform fee is disclosed, rounded to whole KSh, and total is capped', () => {
  assert.equal(calculatePlatformFee(100), 1);
  assert.equal(calculatePlatformFee(1000), 5);
  assert.equal(calculatePlatformFee(150000), 750);
  assert.deepEqual(calculatePaymentTotal(1000), {baseAmount:1000, platformFee:5, totalAmount:1005, platformFeeRate:0.5, platformFeeStatus:'PENDING_PAYMENT'});
  assert.throws(() => calculatePaymentTotal(150000), /must not exceed KSh 150000/);
  assert.throws(() => calculatePlatformFee(0), /positive whole KSh amount/);
});
