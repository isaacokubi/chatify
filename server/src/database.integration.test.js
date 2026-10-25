import test from 'node:test';
import assert from 'node:assert/strict';
import jwt from 'jsonwebtoken';
import mongoose from 'mongoose';
import {encryptSchoolSecret} from './school.js';

const testMongoUri = String(process.env.CHATIFY_MONGO_TEST_URI || '').trim();

test('isolated MongoDB API acceptance: payment callbacks, fee receipt/balance and scoped deletion', {
  skip: !testMongoUri,
  timeout: 180000,
}, async t => {
  const uri = new URL(testMongoUri);
  const databaseName = decodeURIComponent(uri.pathname.replace(/^\//, ''));
  assert.equal(uri.protocol, 'mongodb:',
    'destructive integration setup only accepts a direct MongoDB URI');
  assert.equal(uri.username, '', 'database credentials are not permitted in the disposable test URI');
  assert.equal(uri.password, '', 'database credentials are not permitted in the disposable test URI');
  assert.equal(uri.search, '', 'unexpected MongoDB URI options are refused');
  assert.equal(uri.hash, '', 'unexpected MongoDB URI fragments are refused');
  assert.ok(databaseName === 'chatify' || /^chatify_audit_test(?:_|$)/.test(databaseName),
    'refusing to run destructive integration setup outside the isolated Chatify audit database');
  assert.equal(uri.hostname, '127.0.0.1',
    'the audit integration DB must use the approved loopback address');
  assert.equal(uri.port, '27018',
    'destructive integration setup only targets the approved ephemeral MongoDB container');

  const jwtSecret = 'local-audit-only-signing-secret-0123456789abcdef';
  const platformToken = 'platform-audit-callback-token-0123456789abcdef';
  const schoolToken = 'school-audit-callback-token-0123456789abcdef';
  const posStkToken = 'merchant-stk-audit-token-0123456789abcdef';
  const posC2bToken = 'merchant-c2b-audit-token-0123456789abcdef';
  Object.assign(process.env, {
    NODE_ENV: 'test', PORT: '0', MONGODB_URI: testMongoUri,
    MONGO_AUTO_INDEX: 'true', MONGO_MIN_POOL_SIZE: '0',
    JWT_SECRET: jwtSecret, JWT_EXPIRES_IN: '1h', MPESA_ENV: 'sandbox',
    MPESA_CONSUMER_KEY:'synthetic-key', MPESA_CONSUMER_SECRET:'synthetic-secret', MPESA_SHORTCODE:'123456', MPESA_PASSKEY:'synthetic-passkey',
    MPESA_CALLBACK_URL:`https://api.example.org/api/payments/daraja/callback/${platformToken}`,
    PUBLIC_API_URL:'https://api.example.org', SCHOOL_PAYMENT_ENCRYPTION_KEY:'integration-encryption-key-0123456789abcdef',
    MPESA_CALLBACK_TOKEN: platformToken,
    SCHOOL_DARAJA_CALLBACK_TOKEN: schoolToken,
    POS_STK_CALLBACK_TOKEN: posStkToken,
    POS_C2B_CALLBACK_TOKEN: posC2bToken,
    SMTP_URL: '', SMTP_FROM: '',
  });

  let failNextStk=false;
  const nativeFetch=globalThis.fetch.bind(globalThis);
  globalThis.fetch=async(url,options={})=>{
    if(String(url).startsWith('http://127.0.0.1:'))return nativeFetch(url,options);
    if(String(url).includes('/oauth/'))return {ok:true,json:async()=>({access_token:'synthetic-access-token',expires_in:3600})};
    if(String(url).includes('/mpesa/stkpush/v1/processrequest')){
      if(failNextStk){failNextStk=false;throw Error('synthetic lost STK response');}
      return {ok:true,json:async()=>({ResponseCode:'0',CheckoutRequestID:'SYNTHETIC-CHECKOUT',MerchantRequestID:'SYNTHETIC-MERCHANT'})};
    }
    return {ok:true,json:async()=>({ResponseCode:'0',ResultCode:'0',ResultDesc:'Synthetic query success',CheckoutRequestID:JSON.parse(options.body).CheckoutRequestID})};
  };

  const { server, shutdown } = await import('./index.js');
  t.after(async () => {
    await shutdown();
    await mongoose.connect(testMongoUri, { serverSelectionTimeoutMS: 10000, autoIndex: false });
    try { await mongoose.connection.dropDatabase(); }
    finally { await mongoose.disconnect(); }
  });
  assert.equal(mongoose.connection.readyState, 1, 'MongoDB connection must be ready');
  assert.equal(mongoose.connection.db.databaseName, databaseName);
  await mongoose.connection.dropDatabase();

  const db = mongoose.connection.db;
  const O = mongoose.Types.ObjectId;
  const parentId = new O();
  const otherUserId = new O();
  const schoolAdminId = new O();
  const platformAdminId = new O();
  const schoolId = new O();
  const studentId = new O();
  const structureId = new O();
  const chargeId = new O();
  await db.collection('users').insertMany([
    {_id: parentId, name: 'Synthetic Parent', email: 'parent@example.test', passwordHash: 'unused', status: 'active', role: 'user', sessionVersion: 0, blockedUsers: [], pushTokens: [], privacy: {}},
    {_id: otherUserId, name: 'Other Synthetic User', email: 'other@example.test', passwordHash: 'unused', status: 'active', role: 'user', sessionVersion: 0, blockedUsers: [], pushTokens: [], privacy: {}},
    {_id: schoolAdminId, name: 'Synthetic School Admin', email: 'admin@example.test', passwordHash: 'unused', status: 'active', role: 'user', sessionVersion: 0, blockedUsers: [], pushTokens: [], privacy: {}},
    {_id: platformAdminId, name: 'Synthetic Platform Admin', email: 'platform-admin@example.test', passwordHash: 'unused', status: 'active', role: 'admin', sessionVersion: 0, blockedUsers: [], pushTokens: [], privacy: {}},
  ]);
  const parentAuth = 'Bearer ' + jwt.sign({sub: String(parentId), sv: 0}, jwtSecret, {expiresIn: '1h'});
  const otherAuth = 'Bearer ' + jwt.sign({sub: String(otherUserId), sv: 0}, jwtSecret, {expiresIn: '1h'});
  const schoolAdminAuth = 'Bearer ' + jwt.sign({sub: String(schoolAdminId), sv: 0}, jwtSecret, {expiresIn: '1h'});
  const platformAdminAuth = 'Bearer ' + jwt.sign({sub: String(platformAdminId), sv: 0}, jwtSecret, {expiresIn: '1h'});
  const base = `http://127.0.0.1:${server.address().port}`;
  const postJson = (path, body, token) => fetch(base + path, {
    method: 'POST', headers: {'content-type': 'application/json', ...(token ? {authorization: token} : {})},
    body: JSON.stringify(body), signal: AbortSignal.timeout(30000),
  });
  const getJson = (path, token) => fetch(base + path, {
    headers: {authorization: token}, signal: AbortSignal.timeout(30000),
  });

  const pendingPayment = {
    paymentId: 'AUDIT-PLATFORM-001', requesterId: parentId, payerId: parentId,
    amount: 250, baseAmount: 250, totalAmount: 250, description: 'Disposable audit payment',
    purpose: 'SELF_STK', status: 'PENDING', provider: 'daraja-sandbox',
    payerPhone: '254712345678', phone: '254712345678',
    checkoutRequestId: 'AUDIT-CHECKOUT-001', merchantRequestId: 'AUDIT-MERCHANT-001',
    providerShortcode:'123456', requestedAt: new Date(), createdAt: new Date(), updatedAt: new Date(),
  };
  await db.collection('payments').insertOne(pendingPayment);
  const platformCallback = (token, amount = 250) => postJson(
    `/api/payments/daraja/callback/${token}`,
    {Body: {stkCallback: {
      CheckoutRequestID: pendingPayment.checkoutRequestId,
      MerchantRequestID: pendingPayment.merchantRequestId,
      ResultCode: 0, ResultDesc: 'Synthetic test callback',
      CallbackMetadata: {Item: [
        {Name: 'Amount', Value: amount},
        {Name: 'PhoneNumber', Value: 254712345678},
        {Name: 'MpesaReceiptNumber', Value: 'AUDITPLAT123'},
      ]},
    }}},
  );
  assert.equal((await platformCallback('wrong-test-token')).status, 404,
    'wrong callback token must be rejected before touching payment state');
  assert.equal((await platformCallback(platformToken, 249)).status, 400,
    'amount mismatch must not settle a pending payment');
  assert.equal((await db.collection('payments').findOne({paymentId: pendingPayment.paymentId})).status, 'PENDING');
  const concurrentCallbacks = await Promise.all([
    platformCallback(platformToken), platformCallback(platformToken),
  ]);
  assert.deepEqual(concurrentCallbacks.map(response => response.status), [200, 200]);
  const settledPayment = await db.collection('payments').findOne({paymentId: pendingPayment.paymentId});
  assert.equal(settledPayment.status, 'SUCCESS');
  assert.equal(settledPayment.providerReceipt, 'AUDITPLAT123');
  assert.ok(settledPayment.callbackProcessedAt);
  await platformCallback(platformToken);
  assert.equal(await db.collection('payments').countDocuments({paymentId: pendingPayment.paymentId}), 1);
  assert.equal((await postJson(`/api/payments/daraja/callback/${platformToken}`,{Body:{stkCallback:{CheckoutRequestID:'UNKNOWN-CHECKOUT',MerchantRequestID:'UNKNOWN-MERCHANT',ResultCode:0}}})).status,200,'unknown callback identifiers are acknowledged without financial mutation');
  const queryPayment={...pendingPayment,_id:new O(),paymentId:'AUDIT-QUERY-001',purpose:'REQUEST',status:'PENDING',checkoutRequestId:'AUDIT-QUERY-CHECKOUT',merchantRequestId:'AUDIT-QUERY-MERCHANT',reconciliationAttempts:0};
  await db.collection('payments').insertOne(queryPayment);
  assert.equal((await postJson(`/api/payments/${queryPayment.paymentId}/reconcile`,{},otherAuth)).status,404,'unrelated user cannot query payment status');
  const concurrentQueryResponses=await Promise.all([
    postJson(`/api/payments/${queryPayment.paymentId}/reconcile`,{},parentAuth),
    postJson(`/api/payments/${queryPayment.paymentId}/reconcile`,{},parentAuth),
  ]);
  assert.deepEqual(concurrentQueryResponses.map(response=>response.status).sort(),[200,409],'concurrent status queries are claimed once');
  const queryResponse=concurrentQueryResponses.find(response=>response.status===200);
  assert.equal(queryResponse.status,200);
  assert.match((await queryResponse.json()).reconciliation,/callback receipt evidence/);
  const queriedPayment=await db.collection('payments').findOne({paymentId:queryPayment.paymentId});
  assert.equal(queriedPayment.status,'PENDING','query success without receipt and amount remains pending');
  assert.equal(queriedPayment.reconciliationAttempts,1);
  assert.equal(queriedPayment.providerReceipt,undefined);
  assert.equal((await postJson(`/api/payments/${queryPayment.paymentId}/reconcile`,{},parentAuth)).status,409,'bounded backoff prevents immediate repeated polling');

  failNextStk=true;
  const uncertainResponse=await postJson('/api/payments/send-stk',{amount:55,phone:'254712345678',description:'Synthetic uncertain STK'},parentAuth);
  assert.equal(uncertainResponse.status,503,'lost STK response is not reported as a completed payment');
  const uncertainBody=await uncertainResponse.json();
  const uncertainPayment=await db.collection('payments').findOne({paymentId:uncertainBody.paymentId});
  assert.equal(uncertainPayment.status,'PENDING');
  assert.equal(uncertainPayment.initiationState,'REQUIRES_REVIEW');
  assert.equal(uncertainPayment.initiatedBy.toString(),parentId.toString());
  assert.equal(uncertainPayment.amount,55);
  assert.equal(uncertainPayment.currency,'KES');
  assert.ok(uncertainPayment.initiationHistory.some(event=>event.state==='IN_PROGRESS'));
  assert.ok(uncertainPayment.initiationHistory.some(event=>event.state==='REQUIRES_REVIEW'));
  assert.equal((await postJson('/api/payments/send-stk',{amount:55,phone:'254712345678',description:'Do not duplicate'},parentAuth)).status,409,'uncertain STK cannot be automatically resubmitted');
  assert.equal((await postJson(`/api/payments/${uncertainPayment.paymentId}/reconcile`,{},parentAuth)).status,409,'missing CheckoutRequestID requires review and is not queried');
  assert.equal((await postJson(`/api/admin/payments/${uncertainPayment.paymentId}/review`,{decision:'confirm',reason:'Should not be allowed for ordinary user'},parentAuth)).status,403,'ordinary users cannot manually resolve platform payments');
  const manualReview={
    decision:'confirm',providerReceipt:'AUDITREVIEW1234',evidenceType:'safaricom_statement',
    evidenceReference:'STATEMENT-ITEM-0001',providerTransactionAt:uncertainPayment.requestedAt.toISOString(),
    reason:'Matched the actual Safaricom statement entry to the stored request.',amount:55,currency:'KES',
    payerPhone:'254712345678',shortcode:'123456',accountReference:uncertainPayment.paymentId.replace(/-/g,'').slice(-12),
  };
  assert.equal((await postJson(`/api/admin/payments/${uncertainPayment.paymentId}/review`,{...manualReview,amount:54},platformAdminAuth)).status,400,'mismatched manual evidence cannot confirm');
  const reviewResponses=await Promise.all([
    postJson(`/api/admin/payments/${uncertainPayment.paymentId}/review`,manualReview,platformAdminAuth),
    postJson(`/api/admin/payments/${uncertainPayment.paymentId}/review`,manualReview,platformAdminAuth),
  ]);
  assert.deepEqual(reviewResponses.map(response=>response.status).sort(),[200,200],'concurrent manual review retries are idempotent');
  const manuallyConfirmed=await db.collection('payments').findOne({paymentId:uncertainPayment.paymentId});
  assert.equal(manuallyConfirmed.status,'SUCCESS');
  assert.equal(manuallyConfirmed.confirmationSource,'manual_review');
  assert.equal(manuallyConfirmed.manuallyReviewedBy.toString(),platformAdminId.toString());
  assert.ok(manuallyConfirmed.manuallyReviewedAt instanceof Date);
  assert.equal(manuallyConfirmed.providerReceipt,manualReview.providerReceipt);
  const participantView=await (await getJson(`/api/payments/${uncertainPayment.paymentId}`,parentAuth)).json();
  assert.equal(participantView.payment.confirmationSource,'manual_review');
  assert.equal(participantView.payment.manualReviewReason,undefined,'private review evidence is not exposed to participants');
  assert.equal(participantView.payment.manualReviewEvidenceId,undefined,'private statement reference is not exposed to participants');
  assert.equal((await postJson(`/api/payments/daraja/callback/${platformToken}`,{Body:{stkCallback:{CheckoutRequestID:'NO-UNKNOWN-CHECKOUT',MerchantRequestID:'NO-UNKNOWN-MERCHANT',ResultCode:0}}})).status,200);
  assert.equal((await db.collection('payments').findOne({paymentId:uncertainPayment.paymentId})).confirmationSource,'manual_review','unmatched late callback cannot alter review state');

  const interruptedPayment={...pendingPayment,_id:new O(),paymentId:'AUDIT-INTERRUPTED-INIT',checkoutRequestId:undefined,merchantRequestId:undefined,status:'PENDING',initiationState:'IN_PROGRESS',initiating:true,initiatingAt:new Date(Date.now()-60000),initiatedAt:undefined,initiationUncertainAt:undefined,initiationHistory:[]};
  await db.collection('payments').insertOne(interruptedPayment);
  let interruptedStored=null;
  for(let attempt=0;attempt<25;attempt+=1){await new Promise(resolve=>setTimeout(resolve,200));interruptedStored=await db.collection('payments').findOne({paymentId:interruptedPayment.paymentId});if(interruptedStored.initiationState==='REQUIRES_REVIEW')break;}
  assert.equal(interruptedStored.initiationState,'REQUIRES_REVIEW','stale in-progress attempts recover to explicit review after a process interruption');
  assert.equal(interruptedStored.status,'PENDING');

  const sweptPayment={...queryPayment,_id:new O(),paymentId:'AUDIT-SWEEP-001',checkoutRequestId:'AUDIT-SWEEP-CHECKOUT',merchantRequestId:'AUDIT-SWEEP-MERCHANT',initiatedAt:new Date(Date.now()-180000),reconciliationAttempts:0,nextReconciliationAt:undefined,reconciliationHistory:[]};
  delete sweptPayment.callbackProcessedAt;
  delete sweptPayment.reconciliationClaimedAt;
  delete sweptPayment.nextReconciliationAt;
  await db.collection('payments').insertOne(sweptPayment);
  assert.equal(await db.collection('payments').countDocuments({paymentId:sweptPayment.paymentId,status:'PENDING',providerShortcode:'123456',checkoutRequestId:{$type:'string'},initiatedAt:{$lte:new Date(Date.now()-120000)},callbackProcessedAt:{$exists:false},reconciliationAttempts:{$lt:5},nextReconciliationAt:{$exists:false}}),1,'synthetic checkout meets the background sweep criteria');
  let sweptRecord=null;
  for(let attempt=0;attempt<25;attempt+=1){
    await new Promise(resolve=>setTimeout(resolve,200));
    sweptRecord=await db.collection('payments').findOne({paymentId:sweptPayment.paymentId});
    if(sweptRecord.reconciliationAttempts>0)break;
  }
  assert.equal(sweptRecord.reconciliationAttempts,1,'background sweep queries an old pending checkout once');
  assert.equal(sweptRecord.status,'PENDING','background query success without receipt evidence remains pending');
  const cancelledPlatformPayment = {
    ...pendingPayment, _id: new O(), paymentId: 'AUDIT-PLATFORM-CANCEL',
    checkoutRequestId: 'AUDIT-CHECKOUT-CANCEL', merchantRequestId: 'AUDIT-MERCHANT-CANCEL',
    status: 'PENDING',
  };
  await db.collection('payments').insertOne(cancelledPlatformPayment);
  const cancelledResponse = await postJson(`/api/payments/daraja/callback/${platformToken}`, {
    Body: {stkCallback: {
      CheckoutRequestID: cancelledPlatformPayment.checkoutRequestId,
      MerchantRequestID: cancelledPlatformPayment.merchantRequestId,
      ResultCode: 1032, ResultDesc: 'Synthetic customer cancellation',
    }},
  });
  assert.equal(cancelledResponse.status, 200);
  const cancelledStored = await db.collection('payments').findOne({paymentId: cancelledPlatformPayment.paymentId});
  assert.equal(cancelledStored.status, 'CANCELLED');
  assert.equal(cancelledStored.providerReceipt, undefined);

  await db.collection('schoolworkspaces').insertOne({
    _id: schoolId, name: 'Synthetic Audit School', code: 'AUDIT01', createdBy: schoolAdminId,
    paymentProfile: {method: 'mpesa_paybill', paybillNumber: '123456',darajaMode:'sandbox',darajaConfiguredAt:new Date(),darajaConsumerKeyEnc:encryptSchoolSecret('school-key','integration-encryption-key-0123456789abcdef'),darajaConsumerSecretEnc:encryptSchoolSecret('school-secret','integration-encryption-key-0123456789abcdef'),darajaPasskeyEnc:encryptSchoolSecret('school-passkey','integration-encryption-key-0123456789abcdef')},
  });
  await db.collection('schoolmemberships').insertOne({
    schoolId, userId: parentId, role: 'parent', studentNames: ['Synthetic Learner'], active: true,
  });
  await db.collection('schoolmemberships').insertOne({
    schoolId, userId: schoolAdminId, role: 'admin', studentNames: [], active: true,
  });
  const learnerIds = [new O(), new O()];
  await db.collection('schoolstudents').insertMany(learnerIds.map((id, index) => ({
    _id: id, schoolId, admissionNumber: `AUDIT-CLASS-${index + 1}`,
    fullName: `Synthetic Class Learner ${index + 1}`, className: 'Grade 3', active: true,
    guardianName: 'Synthetic Guardian', createdAt: new Date(), updatedAt: new Date(),
  })));
  assert.equal((await postJson(`/api/schools/${schoolId}/students/promote-class`, {
    fromClass: 'Grade 3', toClass: 'Grade 4', academicYear: '2026',
  }, parentAuth)).status, 403, 'parents cannot promote school records');
  const promotionResponse = await postJson(`/api/schools/${schoolId}/students/promote-class`, {
    fromClass: 'Grade 3', toClass: 'Grade 4', academicYear: '2026',
  }, schoolAdminAuth);
  assert.equal(promotionResponse.status, 200);
  assert.equal((await promotionResponse.json()).promoted, 2);
  const promotedLearner = await db.collection('schoolstudents').findOne({_id: learnerIds[0]});
  assert.equal(promotedLearner.className, 'Grade 4');
  assert.equal(promotedLearner.promotionHistory.length, 1);
  assert.equal((await postJson(`/api/schools/${schoolId}/students/promote-class`, {
    fromClass: 'Grade 3', toClass: 'Grade 4', academicYear: '2026',
  }, schoolAdminAuth)).status, 409, 'retry cannot promote the same class/year twice');
  const transferResponse = await postJson(`/api/schools/${schoolId}/students/${learnerIds[0]}/transfer`, {}, schoolAdminAuth);
  assert.equal(transferResponse.status, 200);
  const transferredLearner = await db.collection('schoolstudents').findOne({_id: learnerIds[0]});
  assert.equal(transferredLearner.active, false);
  assert.ok(transferredLearner.transferredOutAt);
  assert.equal(transferredLearner.promotionHistory.length, 1, 'transfer preserves academic history');
  assert.equal((await postJson(`/api/schools/${schoolId}/students/${learnerIds[0]}/transfer`, {}, schoolAdminAuth)).status, 404,
    'duplicate transfer does not mutate an already archived learner');
  assert.equal((await db.collection('schoolstudents').findOne({_id: learnerIds[1]})).active, true,
    'transferring one learner leaves other learners active');
  await db.collection('schoolstudentcharges').insertOne({
    _id: chargeId, schoolId, studentId, studentName: 'Synthetic Learner',
    admissionNumber: 'AUDIT-001', className: 'Grade 4', academicYear: '2026', term: 'Term 1',
    items: [{code: 'TUITION', description: 'Tuition', amount: 10000}],
    totalAmount: 10000, credits: 0, structureId, structureVersion: 1,
    issuedBy: parentId, issuedAt: new Date(), createdAt: new Date(), updatedAt: new Date(),
  });
  const schoolFee = {
    paymentReference: 'AUDIT-FEE-001', schoolId, parentId,
    studentName: 'Synthetic Learner', studentId, chargeId,
    amount: 3000, term: 'Term 1', academicYear: '2026', className: 'Grade 4',
    paymentMethod: 'mpesa_paybill', destinationNumber: '123456', payerPhone: '254712345678',
    status: 'PENDING_STK', checkoutRequestId: 'AUDIT-SCHOOL-CHECKOUT',
    merchantRequestId: 'AUDIT-SCHOOL-MERCHANT', createdAt: new Date(), updatedAt: new Date(),
  };
  await db.collection('schoolfeepayments').insertOne(schoolFee);
  const pendingReconcileFee={...schoolFee,_id:new O(),paymentReference:'AUDIT-FEE-QUERY',checkoutRequestId:'AUDIT-SCHOOL-QUERY-CHECKOUT',merchantRequestId:'AUDIT-SCHOOL-QUERY-MERCHANT',reconciliationAttempts:0};
  await db.collection('schoolfeepayments').insertOne(pendingReconcileFee);
  const cancelledSchoolFee = {
    ...schoolFee, _id: new O(), paymentReference: 'AUDIT-FEE-CANCEL', amount: 1000,
    checkoutRequestId: 'AUDIT-SCHOOL-CANCEL-CHECKOUT', merchantRequestId: 'AUDIT-SCHOOL-CANCEL-MERCHANT',
  };
  await db.collection('schoolfeepayments').insertOne(cancelledSchoolFee);
  const feesPath = `/api/schools/${schoolId}/fees`;
  const feesBefore = await getJson(feesPath, parentAuth);
  assert.equal(feesBefore.status, 200);
  const beforeBody = await feesBefore.json();
  const pendingFeeView = beforeBody.payments.find(item => item.paymentReference === schoolFee.paymentReference);
  assert.equal(pendingFeeView.status, 'PENDING_STK');
  assert.equal(pendingFeeView.paymentMethodLabel, 'M-Pesa Paybill');
  assert.equal(pendingFeeView.outstandingBalance, 10000);
  assert.equal((await getJson(feesPath, otherAuth)).status, 403,
    'a parent without school membership must not view another school fee ledger');
  assert.equal((await postJson(`${feesPath}/${pendingReconcileFee.paymentReference}/reconcile`,{},parentAuth)).status,403,'school parents cannot trigger staff reconciliation');
  const schoolQueryResponses=await Promise.all([postJson(`${feesPath}/${pendingReconcileFee.paymentReference}/reconcile`,{},schoolAdminAuth),postJson(`${feesPath}/${pendingReconcileFee.paymentReference}/reconcile`,{},schoolAdminAuth)]);
  assert.deepEqual(schoolQueryResponses.map(response=>response.status).sort(),[200,409],'concurrent school reconciliation is claimed exactly once');
  assert.equal((await db.collection('schoolfeepayments').findOne({paymentReference:pendingReconcileFee.paymentReference})).status,'PENDING_STK','status query success cannot issue a school receipt');
  assert.equal((await postJson(`${feesPath}/${pendingReconcileFee.paymentReference}/reconcile`,{},schoolAdminAuth)).status,409,'school status query backoff is enforced');

  const makeSchoolCallback = (payment, token = schoolToken, resultCode = 0, amount = payment.amount, withReceipt = true) => postJson(`/api/schools/daraja/callback/${token}`, {
    Body: {stkCallback: {
      CheckoutRequestID: payment.checkoutRequestId,
      MerchantRequestID: payment.merchantRequestId,
      ResultCode: resultCode, ResultDesc: 'Synthetic test callback',
      ...(resultCode === 0 ? {CallbackMetadata: {Item: [
        {Name: 'Amount', Value: amount},
        {Name: 'PhoneNumber', Value: 254712345678},
        ...(withReceipt?[{Name: 'MpesaReceiptNumber', Value: payment.paymentReference === schoolFee.paymentReference ? 'AUDITSCH123' : 'AUDITCANCEL123'}]:[]),
      ]}} : {}),
    }},
  });
  assert.equal((await makeSchoolCallback(schoolFee, 'incorrect-school-token')).status, 404);
  assert.equal((await db.collection('schoolfeepayments').findOne({paymentReference: schoolFee.paymentReference})).status, 'PENDING_STK');
  assert.equal((await makeSchoolCallback(schoolFee,schoolToken,0,schoolFee.amount-1)).status,200);
  assert.equal((await db.collection('schoolfeepayments').findOne({paymentReference:schoolFee.paymentReference})).status,'PENDING_STK','mismatched callback amount remains pending');
  assert.equal((await makeSchoolCallback(schoolFee,schoolToken,0,schoolFee.amount,false)).status,200);
  assert.equal((await db.collection('schoolfeepayments').findOne({paymentReference:schoolFee.paymentReference})).status,'PENDING_STK','missing provider receipt remains pending');
  assert.equal((await makeSchoolCallback(cancelledSchoolFee, schoolToken, 1032)).status, 200);
  assert.equal((await db.collection('schoolfeepayments').findOne({paymentReference: cancelledSchoolFee.paymentReference})).status, 'CANCELLED');
  const schoolCallback = () => makeSchoolCallback(schoolFee);
  const schoolCallbacks = await Promise.all([schoolCallback(), schoolCallback()]);
  assert.deepEqual(schoolCallbacks.map(response => response.status), [200, 200]);
  const storedFee = await db.collection('schoolfeepayments').findOne({paymentReference: schoolFee.paymentReference});
  assert.equal(storedFee.status, 'CONFIRMED');
  assert.equal(storedFee.mpesaReceipt, 'AUDITSCH123');
  assert.match(storedFee.receiptHtml, /M-Pesa Paybill/);
  assert.equal(await db.collection('schoolfeepayments').countDocuments({mpesaReceipt: 'AUDITSCH123'}), 1);
  const feesAfter = await (await getJson(feesPath, parentAuth)).json();
  const confirmedFeeView = feesAfter.payments.find(item => item.paymentReference === schoolFee.paymentReference);
  assert.equal(confirmedFeeView.status, 'CONFIRMED');
  assert.equal(confirmedFeeView.confirmedPaidForTerm, 3000);
  assert.equal(confirmedFeeView.outstandingBalance, 7000);
  const receiptResponse = await getJson(`${feesPath}/AUDIT-FEE-001/receipt`, parentAuth);
  assert.equal(receiptResponse.status, 200);
  const receipt = await receiptResponse.text();
  assert.match(receipt, /AUDITSCH123/);
  assert.match(receipt, /M-Pesa Paybill/);
  assert.match(receipt, /KSh 7,000/);

  const manualSchoolFee={
    _id:new O(),paymentReference:'AUDIT-SCHOOL-MANUAL',schoolId,parentId,studentName:'Synthetic Learner',studentId,chargeId,
    amount:1000,term:'Term 1',academicYear:'2026',className:'Grade 4',paymentMethod:'mpesa_send_money',destinationNumber:'254700000001',payerPhone:'254712345678',status:'PENDING_VERIFICATION',createdAt:new Date(),updatedAt:new Date(),
  };
  await db.collection('schoolfeepayments').insertOne(manualSchoolFee);
  const manualSchoolBody={mpesaReceipt:'AUDITSEND123',reason:'Matched the incoming transfer to the school bank statement.',evidenceReference:'SCHOOL-STATEMENT-001',evidenceType:'mpesa_statement',amount:1000,currency:'KES',payerPhone:'254712345678',destinationNumber:'254700000001'};
  assert.equal((await postJson(`${feesPath}/${manualSchoolFee.paymentReference}/verify`,manualSchoolBody,parentAuth)).status,403,'school parents cannot manually verify a fee');
  const manualSchoolResponses=await Promise.all([
    postJson(`${feesPath}/${manualSchoolFee.paymentReference}/verify`,manualSchoolBody,schoolAdminAuth),
    postJson(`${feesPath}/${manualSchoolFee.paymentReference}/verify`,manualSchoolBody,schoolAdminAuth),
  ]);
  assert.deepEqual(manualSchoolResponses.map(response=>response.status).sort(),[200,200],'concurrent school manual review is idempotent');
  const storedManualSchool=await db.collection('schoolfeepayments').findOne({paymentReference:manualSchoolFee.paymentReference});
  assert.equal(storedManualSchool.status,'CONFIRMED');
  assert.equal(storedManualSchool.confirmationSource,'manual_review');
  assert.equal(storedManualSchool.manualVerificationDetails.reviewerId.toString(),schoolAdminId.toString());
  assert.match(storedManualSchool.receiptHtml,/MANUALLY REVIEWED/);
  assert.match(storedManualSchool.receiptHtml,/not a Safaricom callback confirmation/i);
  const afterManualFees=await (await getJson(feesPath,parentAuth)).json();
  const manuallyRecordedView=afterManualFees.payments.find(item=>item.paymentReference===manualSchoolFee.paymentReference);
  assert.equal(manuallyRecordedView.confirmationSource,'manual_review');
  assert.equal(manuallyRecordedView.outstandingBalance,6000,'manually verified payment reduces balance once');
  assert.equal(manuallyRecordedView.manualVerificationDetails,undefined,'private evidence stays hidden from parent APIs');
  const failedManualSchool={...manualSchoolFee,_id:new O(),paymentReference:'AUDIT-SCHOOL-FAILED',status:'FAILED',mpesaReceipt:undefined};
  await db.collection('schoolfeepayments').insertOne(failedManualSchool);
  assert.equal((await postJson(`${feesPath}/${failedManualSchool.paymentReference}/verify`,{...manualSchoolBody,mpesaReceipt:'AUDITFAIL123'},schoolAdminAuth)).status,409,'failed payment cannot be manually confirmed');

  const organizationId = new O();
  await db.collection('businessorganizations').insertOne({
    _id: organizationId, name: 'Synthetic Audit Merchant', slug: 'synthetic-audit-merchant',
    ownerId: parentId, country: 'KE', currency: 'KES', members: [], settings: {}, billing: {},
  });
  const stkCharge = {
    _id: new O(), paymentId: 'AUDIT-MERCHANT-STK', organizationId, createdBy: parentId,
    reference: 'AUDITSTK001', amount: 850, baseAmount: 850, totalAmount: 850,
    platformFee: 0, currency: 'KES', description: 'Synthetic merchant STK',
    method: 'mpesa_paybill', destination: {method: 'mpesa_paybill', paybillNumber: '654321'},
    qrPayload: '{}', stkPhone: '254712345678', status: 'PENDING',
    confirmationSource: 'daraja_stk_pending', checkoutRequestId: 'AUDIT-POS-STK-CHECKOUT',
    merchantRequestId: 'AUDIT-POS-STK-MERCHANT', createdAt: new Date(), updatedAt: new Date(),
  };
  await db.collection('businessposcharges').insertOne(stkCharge);
  const posStkCallback = (token = posStkToken, amount = 850) => postJson(`/api/business/pos/stk/callback/${token}`, {
    Body: {stkCallback: {
      CheckoutRequestID: stkCharge.checkoutRequestId,
      MerchantRequestID: stkCharge.merchantRequestId,
      ResultCode: 0, ResultDesc: 'Synthetic merchant callback',
      CallbackMetadata: {Item: [
        {Name: 'Amount', Value: amount},
        {Name: 'PhoneNumber', Value: 254712345678},
        {Name: 'MpesaReceiptNumber', Value: 'AUDITPOS123'},
      ]},
    }},
  });
  assert.equal((await posStkCallback('incorrect-pos-token')).status, 404);
  assert.equal((await posStkCallback(posStkToken, 849)).status, 400);
  assert.equal((await db.collection('businessposcharges').findOne({paymentId: stkCharge.paymentId})).status, 'PENDING');
  const posStkResponses = await Promise.all([posStkCallback(), posStkCallback()]);
  assert.deepEqual(posStkResponses.map(response => response.status), [200, 200]);
  const storedStkCharge = await db.collection('businessposcharges').findOne({paymentId: stkCharge.paymentId});
  assert.equal(storedStkCharge.status, 'SUCCESS');
  assert.equal(storedStkCharge.providerReceipt, 'AUDITPOS123');
  assert.equal(storedStkCharge.organizationId.toString(), organizationId.toString());

  const c2bCharge = {
    ...stkCharge, _id: new O(), paymentId: 'AUDIT-MERCHANT-C2B', reference: 'AUDITC2B001',
    amount: 1200, baseAmount: 1200, totalAmount: 1200,
    destination: {method: 'mpesa_paybill', paybillNumber: '654321'},
    method: 'mpesa_paybill', feeCollectionMode: 'separate', status: 'PENDING',
    confirmationSource: null, providerReceipt: null, checkoutRequestId: null, merchantRequestId: null,
  };
  await db.collection('businessposcharges').insertOne(c2bCharge);
  const c2bCallback = (patch = {}) => postJson(`/api/business/pos/c2b/confirmation/${posC2bToken}`, {
    TransID: 'AUDITC2B123', TransAmount: 1200, BusinessShortCode: '654321',
    BillRefNumber: 'AUDITC2B001', ...patch,
  });
  assert.equal((await postJson('/api/business/pos/c2b/confirmation/wrong-token', {
    TransID: 'AUDITC2B123', TransAmount: 1200, BusinessShortCode: '654321', BillRefNumber: 'AUDITC2B001',
  })).status, 404);
  assert.equal((await c2bCallback({TransAmount: 1199})).status, 200);
  assert.equal((await db.collection('businessposcharges').findOne({paymentId: c2bCharge.paymentId})).status, 'PENDING');
  assert.equal((await c2bCallback()).status, 200);
  const storedC2bCharge = await db.collection('businessposcharges').findOne({paymentId: c2bCharge.paymentId});
  assert.equal(storedC2bCharge.status, 'SUCCESS');
  assert.equal(storedC2bCharge.providerReceipt, 'AUDITC2B123');
  assert.equal(storedC2bCharge.confirmationSource, 'safaricom_c2b');
  await c2bCallback();
  assert.equal(await db.collection('businessposcharges').countDocuments({providerReceipt: 'AUDITC2B123'}), 1);

  const ownContactId = new O();
  const otherContactId = new O();
  await db.collection('savedcontacts').insertMany([
    {_id: ownContactId, userId: parentId, contactUserId: otherUserId},
    {_id: otherContactId, userId: otherUserId, contactUserId: parentId},
  ]);
  const ownContactDelete = await fetch(`${base}/api/contacts/${ownContactId}`, {method: 'DELETE', headers: {authorization: parentAuth}});
  assert.equal(ownContactDelete.status, 204);
  assert.equal((await fetch(`${base}/api/contacts/${otherContactId}`, {method: 'DELETE', headers: {authorization: parentAuth}})).status, 404);
  assert.ok(await db.collection('savedcontacts').findOne({_id: otherContactId}), 'foreign contact must remain');

  const ownMemoryId = new O();
  const foreignMemoryId = new O();
  await db.collection('memories').insertMany([
    {_id: ownMemoryId, userId: parentId, title: 'Synthetic own memory', type: 'NOTE'},
    {_id: foreignMemoryId, userId: otherUserId, title: 'Synthetic private memory', type: 'NOTE'},
  ]);
  assert.equal((await fetch(`${base}/api/memories/${foreignMemoryId}`, {method: 'DELETE', headers: {authorization: parentAuth}})).status, 204);
  assert.ok(await db.collection('memories').findOne({_id: foreignMemoryId}), 'foreign memory must remain');
  assert.equal((await fetch(`${base}/api/memories/${ownMemoryId}`, {method: 'DELETE', headers: {authorization: parentAuth}})).status, 204);
  assert.equal(await db.collection('memories').countDocuments({_id: ownMemoryId}), 0);

  const ownSparkId = new O();
  const foreignSparkId = new O();
  await db.collection('sparks').insertMany([
    {_id: ownSparkId, authorId: parentId, authorName: 'Synthetic Parent', text: 'Own', expiresAt: new Date(Date.now() + 3600000)},
    {_id: foreignSparkId, authorId: otherUserId, authorName: 'Other Synthetic User', text: 'Private', expiresAt: new Date(Date.now() + 3600000)},
  ]);
  assert.equal((await fetch(`${base}/api/sparks/${foreignSparkId}`, {method: 'DELETE', headers: {authorization: parentAuth}})).status, 404);
  assert.ok(await db.collection('sparks').findOne({_id: foreignSparkId}), 'foreign Spark must remain');
  assert.equal((await fetch(`${base}/api/sparks/${ownSparkId}`, {method: 'DELETE', headers: {authorization: parentAuth}})).status, 200);
  assert.equal(await db.collection('sparks').countDocuments({_id: ownSparkId}), 0);

  // A new Mongo client can read the committed callback/receipt state after reconnect.
  await shutdown();
  await mongoose.connect(testMongoUri, {serverSelectionTimeoutMS: 5000, autoIndex: true});
  const recoveredDb = mongoose.connection.db;
  assert.equal((await recoveredDb.collection('payments').findOne({paymentId: pendingPayment.paymentId})).status, 'SUCCESS');
  assert.equal((await recoveredDb.collection('schoolfeepayments').findOne({paymentReference: schoolFee.paymentReference})).status, 'CONFIRMED');
});
