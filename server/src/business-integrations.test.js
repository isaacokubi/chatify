import test from 'node:test';
import assert from 'node:assert/strict';
import {calculateInternationalTotals,extractBusinessMemoryCandidates,createIdempotencyKey,detectOfflineConflict,createEtimsProvider,createMessagingProviders,createLanguageProvider} from './business-integrations.js';

test('international tax calculator handles exclusive and inclusive tax and discounts', () => {
  const exclusive=calculateInternationalTotals([{name:'Consulting',quantity:2,unitPrice:100,discount:10}],{currency:'KES',mode:'exclusive',rate:16});
  assert.equal(exclusive.subtotal,180);
  assert.equal(exclusive.tax,28.8);
  assert.equal(exclusive.total,208.8);
  const inclusive=calculateInternationalTotals([{name:'Book',quantity:1,unitPrice:116}],{currency:'KES',mode:'inclusive',rate:16});
  assert.equal(inclusive.subtotal,100);
  assert.equal(inclusive.tax,16);
  assert.equal(inclusive.total,116);
});

test('international tax calculator rejects invalid currency and tax mode', () => {
  assert.throws(()=>calculateInternationalTotals([{name:'x',quantity:1,unitPrice:1}],{currency:'FAKE'}),/Unsupported currency/);
  assert.throws(()=>calculateInternationalTotals([{name:'x',quantity:1,unitPrice:1}],{mode:'guess'}),/Tax mode/);
});

test('business memory extractor returns reviewable suggestions without saving records', () => {
  const candidates=extractBusinessMemoryCandidates('Please follow up with the customer tomorrow; invoice balance is KSh 4,500.');
  assert.ok(candidates.some(item=>item.type==='PAYMENT'));
  assert.ok(candidates.some(item=>item.type==='TASK'));
  assert.ok(candidates.some(item=>item.type==='EVENT'));
  assert.ok(candidates.every(item=>item.confidence>0&&item.confidence<=1));
  assert.deepEqual(extractBusinessMemoryCandidates(''),[]);
});

test('offline sync requires a valid base version and detects stale writes', () => {
  assert.deepEqual(detectOfflineConflict('2026-10-12T10:00:00Z','2026-10-12T10:00:00Z'),{conflict:false});
  assert.deepEqual(detectOfflineConflict('2026-10-12T10:00:01Z','2026-10-12T10:00:00Z'),{conflict:true,reason:'record_changed_on_server'});
  assert.deepEqual(detectOfflineConflict('2026-10-12T10:00:00Z',null),{conflict:true,reason:'base_version_required'});
});

test('idempotency keys are constrained and deterministic', () => {
  assert.equal(createIdempotencyKey('sync:customer:1234'),'sync:customer:1234');
  assert.throws(()=>createIdempotencyKey('short'),/Idempotency key/);
  assert.throws(()=>createIdempotencyKey('bad key value'),/Idempotency key/);
});

test('eTIMS adapter remains disabled without credentials', async () => {
  const provider=createEtimsProvider({});
  assert.equal(provider.configured,false);
  await assert.rejects(()=>provider.submitInvoice({number:'INV-1'}),/not configured/);
});

test('SMS and WhatsApp adapters fail closed when not configured', async () => {
  const provider=createMessagingProviders({});
  await assert.rejects(()=>provider.sendSms({to:'+254700000000',text:'Hello'}),/not configured/);
  await assert.rejects(()=>provider.sendWhatsApp({to:'254700000000',text:'Hello'}),/not configured/);
});

test('language provider fails clearly when no key is configured', async () => {
  const provider=createLanguageProvider({});
  await assert.rejects(()=>provider.translateText({text:'Hello',targetLanguage:'Kiswahili'}),/not configured/);
});
