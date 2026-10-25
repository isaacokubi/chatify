import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveMpesaProvider, canCancelPayment, resolveCallbackOutcome, canTransitionPayment, buildDarajaPaymentTransition, calculatePaymentTotal, buildPaymentRetryFields, isValidDarajaCallbackToken, validateDarajaCallbackConfiguration, classifyStkInitiationFailure} from './payments.js';

test('only pre-STK failures and explicit Daraja rejection permit another initiation attempt', () => {
  for (const stage of ['oauth_transport','oauth_auth','stk_rejected','stk_validation']) {
    assert.equal(classifyStkInitiationFailure(stage),'DEFINITIVE_FAILURE',stage);
  }
  for (const stage of ['stk_transport','stk_response','query_transport',undefined,'unknown']) {
    assert.equal(classifyStkInitiationFailure(stage),'REQUIRES_REVIEW',String(stage));
  }
});

test('Daraja callback token validation rejects missing, short and mismatched tokens', () => {
  const expected = '0123456789abcdef'.repeat(4);
  assert.equal(isValidDarajaCallbackToken(expected, expected), true);
  assert.equal(isValidDarajaCallbackToken(`${expected}x`, expected), false);
  assert.equal(isValidDarajaCallbackToken('short-token', expected), false);
  assert.equal(isValidDarajaCallbackToken(expected, 'short-token'), false);
  assert.equal(isValidDarajaCallbackToken(undefined, expected), false);
});

test('live Daraja configuration requires its callback URL to carry the configured token path', () => {
  const token = 'abcdef0123456789'.repeat(4);
  assert.doesNotThrow(() => validateDarajaCallbackConfiguration(
    `https://api.example.org/api/payments/daraja/callback/${token}`, token,
  ));
  assert.throws(() => validateDarajaCallbackConfiguration(
    'https://api.example.org/api/payments/daraja/callback', token,
  ), /authenticated callback path/);
  assert.throws(() => validateDarajaCallbackConfiguration(
    `https://api.example.org/api/payments/daraja/callback/${token}`, 'short',
  ), /at least 32 characters/);
});

test('payment retry preserves workspace billing identity without adding commissions', () => {
  const requestedAt = new Date('2026-10-22T00:00:00.000Z');
  const fields = buildPaymentRetryFields({
    requesterId: 'owner-1', payerId: 'owner-1', amount: 1000,
    billingType: 'workspace_subscription', billingWorkspaceType: 'business',
    billingWorkspaceId: 'workspace-1', description: 'Monthly subscription',
    purpose: 'SELF_STK', payerPhone: '254712345678',
  }, 'daraja-production', requestedAt);
  assert.equal(fields.billingType, 'workspace_subscription');
  assert.equal(fields.billingWorkspaceType, 'business');
  assert.equal(fields.billingWorkspaceId, 'workspace-1');
  assert.equal(fields.amount, 1000);
  assert.equal(fields.totalAmount, 1000);
  assert.equal(fields.platformFee, 0);
  assert.equal(fields.provider, 'daraja-production');
  assert.equal(fields.requestedAt, requestedAt);
});

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

test('Daraja provider resolution requires a secret token on its configured callback URL', () => {
  const token = 'callback-auth-token-0123456789abcdef'.repeat(2);
  const env = {
    NODE_ENV: 'test', MPESA_ENV: 'sandbox', MPESA_CONSUMER_KEY: 'test-key',
    MPESA_CONSUMER_SECRET: 'test-secret', MPESA_SHORTCODE: '123456', MPESA_PASSKEY: 'test-passkey',
    MPESA_CALLBACK_URL: `https://api.example.org/api/payments/daraja/callback/${token}`,
  };
  assert.throws(() => resolveMpesaProvider(env), /callback token of at least 32 characters/);
  assert.doesNotThrow(() => resolveMpesaProvider({...env, MPESA_CALLBACK_TOKEN: token}));
  assert.throws(() => resolveMpesaProvider({...env, MPESA_CALLBACK_TOKEN: token, MPESA_CALLBACK_URL: 'https://api.example.org/api/payments/daraja/callback'}), /authenticated callback path/);
});

test('live Daraja mode reports callback prerequisites before credential validation', () => {
  assert.throws(
    () => resolveMpesaProvider({NODE_ENV: 'production', MPESA_ENV: 'production'}),
    /Invalid Daraja callback configuration.*MPESA_CALLBACK_TOKEN.*MPESA_CALLBACK_URL/,
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

test('Daraja OAuth rejection and malformed responses fail closed without exposing provider data', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const responses = [
    {ok:false, json:async()=>({error:'invalid_client', error_description:'private provider detail'})},
    {ok:true, json:async()=>{throw new Error('malformed provider body')}},
  ];
  let calls = 0;
  const provider = createDarajaProvider({
    mode:'sandbox', consumerKey:'test-key', consumerSecret:'do-not-log-this-secret',
    shortcode:'123456', passkey:'test-passkey',
    callbackUrl:'https://api.example.org/api/payments/daraja/callback',
  }, async () => responses[calls++]);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    await assert.rejects(provider.initiate({
      paymentId:'test-payment', amount:10, phone:'254712345678', description:'Test',
    }), error => error.stage === 'oauth_auth' &&
      error.message === 'Daraja authentication failed' &&
      !error.message.includes('do-not-log-this-secret') &&
      !error.message.includes('private provider detail'));
  }
  assert.equal(calls, 2);
});

test('Daraja OAuth token is reused until its safety window expires, then refreshed', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  let now = 1000;
  let oauthCalls = 0;
  let stkCalls = 0;
  const provider = createDarajaProvider({
    mode:'sandbox', consumerKey:'test-key', consumerSecret:'test-secret',
    shortcode:'123456', passkey:'test-passkey',
    callbackUrl:'https://api.example.org/api/payments/daraja/callback',
  }, async url => {
    if (url.includes('/oauth/')) {
      oauthCalls += 1;
      return {ok:true, json:async()=>({access_token:`token-${oauthCalls}`, expires_in:60})};
    }
    stkCalls += 1;
    return {ok:true, json:async()=>({
      ResponseCode:'0', CheckoutRequestID:`checkout-${stkCalls}`, MerchantRequestID:`merchant-${stkCalls}`,
    })};
  }, () => now);

  const request = () => provider.initiate({
    paymentId:'test-payment', amount:10, phone:'254712345678', description:'Test',
  });
  await request();
  await request();
  assert.equal(oauthCalls, 1, 'valid OAuth token is cached');

  // The adapter refreshes 30 seconds before provider expiry.
  now += 30_001;
  await request();
  assert.equal(oauthCalls, 2, 'expired-with-safety-window token is refreshed');
  assert.equal(stkCalls, 3);
});

test('Daraja STK status query uses matching environment, shortcode fields and never confirms without callback metadata', async () => {
  const {createDarajaProvider} = await import('./payments.js');
  const requests=[];
  const provider=createDarajaProvider({mode:'sandbox',consumerKey:'key',consumerSecret:'secret',shortcode:'123456',passkey:'pass',callbackUrl:'https://api.example.org/api/payments/daraja/callback'},async(url,options={})=>{
    requests.push({url,options});
    return url.includes('/oauth/')?{ok:true,json:async()=>({access_token:'private-token',expires_in:3600})}:{ok:true,json:async()=>({ResponseCode:'0',ResultCode:'0',ResultDesc:'Success',CheckoutRequestID:'checkout-123'})};
  },()=>Date.parse('2026-10-25T08:09:10Z'));
  const result=await provider.queryStatus({checkoutRequestId:'checkout-123',now:new Date('2026-10-25T08:09:10Z')});
  assert.equal(result.state,'SUCCESS_EVIDENCE_INCOMPLETE');
  assert.equal(requests[1].url,'https://sandbox.safaricom.co.ke/mpesa/stkpushquery/v1/query');
  const body=JSON.parse(requests[1].options.body);
  assert.equal(body.BusinessShortCode,'123456');
  assert.equal(body.CheckoutRequestID,'checkout-123');
  assert.equal(body.Timestamp,'20261025110910');
  assert.equal(requests[1].options.headers.Authorization,'Bearer private-token');
  assert.ok(!JSON.stringify(result).includes('private-token'));
});

test('Daraja status query classifies ambiguous responses as pending and fails closed on transport or malformed responses', async()=>{
  const {createDarajaProvider,reconciliationRetryAt}=await import('./payments.js');
  for(const body of [{ResponseCode:'0',ResultCode:''},{ResponseCode:'1',ResultCode:'1032'},{ResponseCode:'0'}]){
    const provider=createDarajaProvider({mode:'production',consumerKey:'k',consumerSecret:'s',shortcode:'123456',passkey:'p',callbackUrl:'https://api.example.org/cb'},async url=>url.includes('/oauth/')?{ok:true,json:async()=>({access_token:'x',expires_in:3600})}:{ok:true,json:async()=>body});
    assert.equal((await provider.queryStatus({checkoutRequestId:'checkout'})).state,'PENDING');
  }
  const transport=createDarajaProvider({mode:'sandbox',consumerKey:'k',consumerSecret:'s',shortcode:'123456',passkey:'p',callbackUrl:'https://api.example.org/cb'},async url=>url.includes('/oauth/')?{ok:true,json:async()=>({access_token:'x',expires_in:3600})}:Promise.reject(Error('offline')));
  await assert.rejects(transport.queryStatus({checkoutRequestId:'checkout'}),e=>e.stage==='query_transport');
  const malformed=createDarajaProvider({mode:'sandbox',consumerKey:'k',consumerSecret:'s',shortcode:'123456',passkey:'p',callbackUrl:'https://api.example.org/cb'},async url=>url.includes('/oauth/')?{ok:true,json:async()=>({access_token:'x',expires_in:3600})}:{ok:true,json:async()=>{throw Error('bad json')}});
  await assert.rejects(malformed.queryStatus({checkoutRequestId:'checkout'}),e=>e.stage==='query_response');
  assert.equal(reconciliationRetryAt(1,new Date(0)).getTime(),60_000);
  assert.equal(reconciliationRetryAt(5,new Date(0)).getTime(),960_000);
});

test('Daraja accepted status query maps provider failure and cancellation without confirming success',async()=>{
  const {createDarajaProvider}=await import('./payments.js');
  for(const [code,state] of [['1032','CANCELLED'],['1','FAILED']]){
    const provider=createDarajaProvider({mode:'sandbox',consumerKey:'k',consumerSecret:'s',shortcode:'123456',passkey:'p',callbackUrl:'https://api.example.org/cb'},async url=>url.includes('/oauth/')?{ok:true,json:async()=>({access_token:'x',expires_in:3600})}:{ok:true,json:async()=>({ResponseCode:'0',ResultCode:code,ResultDesc:'Synthetic result'})});
    const result=await provider.queryStatus({checkoutRequestId:'checkout'});
    assert.equal(result.state,state);
    assert.notEqual(result.state,'SUCCESS');
  }
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
    {Name: 'Amount', Value: 450}, {Name: 'PhoneNumber', Value: 254712345678}, {Name: 'MpesaReceiptNumber', Value: 'QWERTY1234'},
  ]}};
  assert.equal(resolveCallbackOutcome(callback, payment).status, 'SUCCESS');
  assert.equal(resolveCallbackOutcome(callback, payment).receipt, 'QWERTY1234');
  assert.equal(resolveCallbackOutcome({...callback, CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 451}, {Name: 'PhoneNumber', Value: 254712345678},
  ]}}, payment).error, 'mismatch');
  assert.equal(resolveCallbackOutcome({...callback, CallbackMetadata: {Item: [
    {Name: 'Amount', Value: 450}, {Name: 'PhoneNumber', Value: 254700000000},
  ]}}, payment).error, 'mismatch');
});


test('successful payment callback requires a provider receipt', () => {
  const payment = {amount:450, phone:'254712345678'};
  const callback = {ResultCode:0, ResultDesc:'Success', CallbackMetadata:{Item:[
    {Name:'Amount',Value:450}, {Name:'PhoneNumber',Value:254712345678},
  ]}};
  assert.equal(resolveCallbackOutcome(callback,payment).error,'malformed');
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

test('callback transition maps success, cancellation, rejection and validation failures without premature credit', () => {
  const payment = {status:'PENDING',amount:450,phone:'254712345678'};
  const success = {ResultCode:0,ResultDesc:'Success',CallbackMetadata:{Item:[
    {Name:'Amount',Value:450},{Name:'PhoneNumber',Value:254712345678},{Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}};
  const accepted = buildDarajaPaymentTransition(payment, success, new Date('2026-10-25T10:00:00Z'));
  assert.equal(payment.status, 'PENDING'); // STK initiation/acceptance state is not mutated by the transition builder.
  assert.equal(accepted.update.$set.status, 'SUCCESS');
  assert.equal(accepted.update.$set.providerReceipt, 'QWERTY1234');
  assert.equal(accepted.update.$set.completedAt.toISOString(), '2026-10-25T10:00:00.000Z');
  assert.equal(buildDarajaPaymentTransition(payment, {...success, CallbackMetadata:{Item:[
    {Name:'Amount',Value:451},{Name:'PhoneNumber',Value:254712345678},{Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}}).error, 'mismatch');
  assert.equal(buildDarajaPaymentTransition(payment, {...success, CallbackMetadata:{Item:[
    {Name:'Amount',Value:450},{Name:'PhoneNumber',Value:254700000000},{Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}}).error, 'mismatch');
  assert.equal(buildDarajaPaymentTransition(payment, {ResultCode:'bad'}).error, 'malformed');
  assert.equal(buildDarajaPaymentTransition(payment, {ResultCode:1032}).update.$set.status, 'CANCELLED');
  assert.equal(buildDarajaPaymentTransition(payment, {ResultCode:1,ResultDesc:'Rejected'}).update.$set.status, 'FAILED');
  assert.equal(buildDarajaPaymentTransition({...payment,status:'SUCCESS',callbackProcessedAt:new Date()}, success).duplicate, true);
});

test('concurrent callback simulations atomically apply one ledger transition and duplicate retries add no second credit', async () => {
  const receipt = {ResultCode:0,ResultDesc:'Success',CallbackMetadata:{Item:[
    {Name:'Amount',Value:450},{Name:'PhoneNumber',Value:254712345678},{Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}};
  const record = {paymentId:'pay-1',checkoutRequestId:'checkout-1',merchantRequestId:'merchant-1',provider:'daraja-sandbox',status:'PENDING',amount:450,phone:'254712345678',ledgerCredits:0};
  const Payment = {
    async findOne() { return {...record}; },
    async findOneAndUpdate(filter, update) {
      if (record.status !== filter.status || record.callbackProcessedAt ||
          record.checkoutRequestId !== filter.checkoutRequestId || record.merchantRequestId !== filter.merchantRequestId) return null;
      Object.assign(record, update.$set);
      if (record.status === 'SUCCESS') record.ledgerCredits += record.amount;
      return {...record};
    },
  };
  const processCallback = async () => {
    const payment = await Payment.findOne();
    const transition = buildDarajaPaymentTransition(payment, receipt);
    if (transition.error || transition.duplicate) return transition;
    const saved = await Payment.findOneAndUpdate({
      status:'PENDING',callbackProcessedAt:{$exists:false},
      checkoutRequestId:'checkout-1',merchantRequestId:'merchant-1',
    }, transition.update);
    return saved ? {applied:true,payment:saved} : {duplicate:true};
  };
  const concurrent = await Promise.all([processCallback(),processCallback()]);
  assert.equal(concurrent.filter(result => result.applied).length, 1);
  assert.equal(record.status, 'SUCCESS');
  assert.equal(record.providerReceipt, 'QWERTY1234');
  assert.equal(record.ledgerCredits, 450);
  assert.equal((await processCallback()).duplicate, true);
  assert.equal(record.ledgerCredits, 450);
});


test('payment totals are commission-free by default', () => {
  assert.deepEqual(calculatePaymentTotal(1000), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
  assert.deepEqual(calculatePaymentTotal(150000), {
    baseAmount:150000, platformFee:0, totalAmount:150000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('legacy fee options cannot re-enable a transaction commission', () => {
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:true, feeRate:0.5}), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
  assert.deepEqual(calculatePaymentTotal(150000, {applicable:true, feeRate:5}), {
    baseAmount:150000, platformFee:0, totalAmount:150000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('ordinary user-to-user transfers do not receive a Chatify platform fee', () => {
  assert.deepEqual(calculatePaymentTotal(1000, {applicable:false}), {
    baseAmount:1000, platformFee:0, totalAmount:1000, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
  });
});

test('business and school payment totals stay commission-free regardless of legacy settings', () => {
  for (const amount of [100, 1000, 150000]) {
    assert.deepEqual(calculatePaymentTotal(amount, {applicable:true, feeRate:0.25}), {
      baseAmount:amount, platformFee:0, totalAmount:amount, platformFeeRate:0, platformFeeStatus:'NOT_APPLICABLE'
    });
  }
});

test('legacy separate-mode payment callback still matches only the original base amount', () => {
  const payment = {amount:1000, baseAmount:1000, totalAmount:1005, feeCollectionMode:'separate', phone:'254712345678'};
  const callback = {ResultCode:0, ResultDesc:'Success', CallbackMetadata:{Item:[
    {Name:'Amount',Value:1000}, {Name:'PhoneNumber',Value:254712345678}, {Name:'MpesaReceiptNumber',Value:'QWERTY1234'},
  ]}};
  assert.equal(resolveCallbackOutcome(callback,payment).status,'SUCCESS');
  assert.equal(resolveCallbackOutcome({...callback,CallbackMetadata:{Item:[
    {Name:'Amount',Value:1005}, {Name:'PhoneNumber',Value:254712345678},
  ]}},payment).error,'mismatch');
});
