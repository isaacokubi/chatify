import test from 'node:test';
import assert from 'node:assert/strict';
import {slugifyBusinessName, offlineCreateId, calculateDocumentTotals, canTransitionBusinessDocument, buildBusinessBriefing, buildStorefrontOrderLines, resolveSellerMpesaPhone, applyExplicitMessagingConsent, archiveBusinessCustomer, invoiceStkInitiationFailureFields, businessInvoiceStkProviderAllowed} from './business.js';

test('invoice STK cannot send a merchant invoice to the platform Daraja shortcode', () => {
  assert.equal(businessInvoiceStkProviderAllowed({name:'mock',isMock:true}), true);
  assert.equal(businessInvoiceStkProviderAllowed({name:'daraja-sandbox',isMock:false}), false);
  assert.equal(businessInvoiceStkProviderAllowed({name:'daraja-production',isMock:false}), false);
});

test('invoice STK uncertainty stays pending and blocks retries while definite pre-STK failure can retry', () => {
  const now = new Date('2026-10-26T12:00:00.000Z');
  const uncertain = invoiceStkInitiationFailureFields(Object.assign(new Error('network failure'), {stage:'stk_transport'}), now);
  assert.equal(uncertain.status, 'PENDING');
  assert.equal(uncertain.initiating, false);
  assert.equal(uncertain.initiationState, 'REQUIRES_REVIEW');
  assert.equal(uncertain.initiatedAt, now);
  assert.equal(uncertain.initiationUncertainAt, now);
  assert.equal(uncertain.callbackProcessedAt, undefined);
  assert.equal(uncertain.initiationHistory[0].stage, 'stk_transport');

  const rejected = invoiceStkInitiationFailureFields(Object.assign(new Error('auth failed'), {stage:'oauth_auth'}), now);
  assert.equal(rejected.status, 'FAILED');
  assert.equal(rejected.initiationState, 'DEFINITIVE_FAILURE');
  assert.equal(rejected.callbackProcessedAt, now);
  assert.equal(rejected.initiatedAt, undefined);

  for (const stage of ['stk_transport','stk_response','unknown']) {
    const uncertainOutcome = invoiceStkInitiationFailureFields(Object.assign(new Error('inconclusive'), {stage}), now);
    assert.equal(uncertainOutcome.status, 'PENDING', `${stage} must keep the invoice payment locked`);
    assert.equal(uncertainOutcome.initiationState, 'REQUIRES_REVIEW');
  }
});

test('business customer archive is tenant scoped, preserves record, and duplicate/concurrent retries are harmless', async () => {
  const customer = {_id: 'customer-1', organizationId: 'org-1', name: 'Amina', salesHistory: ['invoice-1']};
  const filters = [];
  const Customer = {
    async findOneAndUpdate(filter, update, options) {
      filters.push(filter);
      assert.deepEqual(options, {new: true});
      if (String(filter._id) !== String(customer._id) ||
          String(filter.organizationId) !== String(customer.organizationId) ||
          customer.archivedAt) return null;
      customer.archivedAt = update.$set.archivedAt;
      return customer;
    },
  };
  const archivedAt = new Date('2026-10-25T10:00:00.000Z');
  const results = await Promise.all([
    archiveBusinessCustomer(Customer, {organizationId:'org-1', customerId:'customer-1', archivedAt}),
    archiveBusinessCustomer(Customer, {organizationId:'org-1', customerId:'customer-1', archivedAt}),
  ]);
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(await archiveBusinessCustomer(Customer, {organizationId:'org-2', customerId:'customer-1'}), null);
  assert.equal(await archiveBusinessCustomer(Customer, {organizationId:'org-1', customerId:'missing'}), null);
  assert.deepEqual(customer.salesHistory, ['invoice-1']);
  assert.equal(customer.archivedAt, archivedAt);
  assert.ok(filters.every(filter => filter.archivedAt.$exists === false));
});

test('explicit messaging opt-in is captured once and never inferred', () => {
  const capturedAt = new Date('2026-10-23T08:00:00.000Z');
  const customer = {messagingConsent: false};
  assert.equal(applyExplicitMessagingConsent(customer, false, capturedAt), false);
  assert.equal(customer.messagingConsent, false);
  assert.equal(applyExplicitMessagingConsent(customer, true, capturedAt), true);
  assert.equal(customer.messagingConsent, true);
  assert.equal(customer.consentCapturedAt, capturedAt);
  assert.equal(applyExplicitMessagingConsent(customer, true, new Date()), false);
  const optedOut = {messagingConsent: false};
  assert.equal(applyExplicitMessagingConsent(optedOut, undefined), false);
});

test('offline create IDs are stable per organization and mutation and isolated across organizations', () => {
  const first = offlineCreateId('org-1', 'mobile:customer:operation-1');
  assert.equal(first, offlineCreateId('org-1', 'mobile:customer:operation-1'));
  assert.match(first, /^[a-f0-9]{24}$/);
  assert.notEqual(first, offlineCreateId('org-2', 'mobile:customer:operation-1'));
  assert.notEqual(first, offlineCreateId('org-1', 'mobile:customer:operation-2'));
});

test('business slugs are URL-safe and deterministic', () => {
  assert.equal(slugifyBusinessName('Baraka & Sons Retail'), 'baraka-sons-retail');
  assert.equal(slugifyBusinessName('  Café Nairobi  '), 'cafe-nairobi');
  assert.equal(slugifyBusinessName('!!!'), '');
});

test('document totals are calculated on the server with rounding', () => {
  assert.deepEqual(calculateDocumentTotals([
    {name:'Book', quantity:2, unitPrice:125.5},
    {name:'Delivery', quantity:1, unitPrice:50},
  ], 16), {
    items:[
      {catalogItemId:undefined,name:'Book',quantity:2,unitPrice:125.5,lineTotal:251},
      {catalogItemId:undefined,name:'Delivery',quantity:1,unitPrice:50,lineTotal:50},
    ],
    subtotal:301,tax:48.16,taxRate:16,total:349.16,
  });
});

test('document totals reject malformed items and excessive tax', () => {
  assert.throws(() => calculateDocumentTotals([], 0), /between 1 and 100/);
  assert.throws(() => calculateDocumentTotals([{name:'x',quantity:0,unitPrice:1}], 0), /positive quantity/);
  assert.throws(() => calculateDocumentTotals([{name:'x',quantity:1,unitPrice:1}], 101), /between 0 and 100/);
});

test('document lifecycle allows valid sale flow and rejects backwards transitions', () => {
  assert.equal(canTransitionBusinessDocument('draft','sent'), true);
  assert.equal(canTransitionBusinessDocument('sent','accepted'), true);
  assert.equal(canTransitionBusinessDocument('accepted','part_paid'), true);
  assert.equal(canTransitionBusinessDocument('part_paid','paid'), true);
  assert.equal(canTransitionBusinessDocument('paid','fulfilled'), true);
  assert.equal(canTransitionBusinessDocument('paid','draft'), false);
  assert.equal(canTransitionBusinessDocument('fulfilled','cancelled'), false);
});

test('business briefing identifies overdue work, due-soon tasks and outstanding value', () => {
  const now = new Date('2026-10-12T10:00:00.000Z');
  const result = buildBusinessBriefing({
    now,
    tasks:[
      {_id:'a',title:'Late callback',status:'open',dueAt:'2026-10-11T10:00:00.000Z'},
      {_id:'b',title:'Send quote',status:'in_progress',dueAt:'2026-10-12T20:00:00.000Z'},
      {_id:'c',title:'Done task',status:'done',dueAt:'2026-10-10T10:00:00.000Z'},
    ],
    documents:[
      {status:'sent',total:500,paidAmount:100},
      {status:'paid',total:200,paidAmount:200},
      {status:'part_paid',total:300,paidAmount:50},
    ],
    cases:[{status:'open'},{status:'resolved'},{status:'waiting_team'}],
  });
  assert.equal(result.overdueTasks,1);
  assert.equal(result.tasksDueWithin24Hours,1);
  assert.equal(result.outstandingDocuments,2);
  assert.equal(result.outstandingAmount,650);
  assert.equal(result.unresolvedCases,2);
  assert.equal(result.nextActions.length,2);
});


test('storefront order lines use server catalogue prices and enforce M-Pesa limits', () => {
  const products = [
    {_id:'a', name:'Notebook', price:120, currency:'KES', active:true, stock:8},
    {_id:'b', name:'Pen', price:30, currency:'KES', active:true, stock:0},
  ];
  const order = buildStorefrontOrderLines([{itemId:'a',quantity:2},{itemId:'b',quantity:1}], products);
  assert.equal(order.total, 270);
  assert.equal(order.items[0].lineTotal, 240);
  assert.equal(order.items[0].unitPrice, 120);
  assert.throws(() => buildStorefrontOrderLines([{itemId:'a',quantity:9}], products), /Not enough stock/);
  assert.throws(() => buildStorefrontOrderLines([{itemId:'a',quantity:1}], [{...products[0],price:120.5}]), /whole-number price/);
  assert.throws(() => buildStorefrontOrderLines([{itemId:'missing',quantity:1}], products), /no longer available/);
  assert.throws(() => buildStorefrontOrderLines([{itemId:'a',quantity:100}], [{...products[0],price:2000,stock:0}]), /KSh 1 and KSh 150,000/);
});


test('seller M-Pesa number prefers saved choice, then registered phone, then business contact', () => {
  assert.equal(resolveSellerMpesaPhone({mpesaRecipientPhone: '0712 345 678'}, '0711111111', '0722222222'), '254712345678');
  assert.equal(resolveSellerMpesaPhone({}, '0711 111 111', '0722222222'), '254711111111');
  assert.equal(resolveSellerMpesaPhone({}, 'not-a-phone', '+254722222222'), '254722222222');
  assert.equal(resolveSellerMpesaPhone({}, 'not-a-phone', 'also-invalid'), null);
});
