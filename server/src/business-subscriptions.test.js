import test from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {normalizeSubscriptionRequest,normalizeSubscriptionEvent,verifyBillingSignature,subscriptionStateForEvent} from './business-subscriptions.js';
test('only supported paid plans can be requested',()=>{
 assert.deepEqual(normalizeSubscriptionRequest({plan:'teams'}),{plan:'teams'});
 assert.throws(()=>normalizeSubscriptionRequest({plan:'free'}),/paid plan/);
 assert.throws(()=>normalizeSubscriptionRequest({plan:'bogus'}),/paid plan/);
});
test('billing events validate identifiers and activation plan',()=>{
 assert.equal(normalizeSubscriptionEvent({eventId:'evt_12345678',organizationId:'507f1f77bcf86cd799439011',eventType:'subscription.activated',plan:'teams'}).plan,'teams');
 assert.throws(()=>normalizeSubscriptionEvent({eventId:'x',organizationId:'bad',eventType:'subscription.activated',plan:'teams'}));
 assert.throws(()=>normalizeSubscriptionEvent({eventId:'evt_12345678',organizationId:'507f1f77bcf86cd799439011',eventType:'subscription.activated',plan:'free'}));
});
test('HMAC signature matches exact request bytes and rejects tampering',()=>{
 const raw=Buffer.from('{"eventId":"evt_12345678"}');
 const signature=createHmac('sha256','secret').update(raw).digest('hex');
 assert.equal(verifyBillingSignature(raw,signature,'secret'),true);
 assert.equal(verifyBillingSignature(Buffer.from(raw.toString()+' '),signature,'secret'),false);
 assert.equal(verifyBillingSignature(raw,signature,''),false);
});
test('activation applies a paid plan and cancellation downgrades to free',()=>{
 const end=new Date(Date.now()+86400000);
 assert.equal(subscriptionStateForEvent({eventType:'subscription.activated',plan:'teams',currentPeriodEnd:end}).plan,'teams');
 assert.equal(subscriptionStateForEvent({eventType:'subscription.canceled'}).plan,'free');
 assert.throws(()=>subscriptionStateForEvent({eventType:'subscription.activated',plan:'teams',currentPeriodEnd:new Date(0)}));
});
