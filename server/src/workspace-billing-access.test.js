import test from 'node:test';
import assert from 'node:assert/strict';
import {workspaceBillingLock, isWorkspaceBillingActive} from './workspace-billing-access.js';

function mongooseWithGracePeriod(gracePeriodDays = 3) {
  return {models:{WorkspaceBillingSettings:{findOne:()=>({select:()=>({lean:async()=>({gracePeriodDays})})})}}};
}

test('legacy workspaces remain accessible until billing is explicitly enforced', async()=>{
  assert.equal(await workspaceBillingLock(mongooseWithGracePeriod(),{billing:{}}),null);
});

test('paid workspace remains accessible inside configured grace period', async()=>{
  const now=new Date('2026-10-22T00:00:00.000Z');
  const result=await workspaceBillingLock(mongooseWithGracePeriod(3),{billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}},now);
  assert.equal(result,null);
});

test('workspace locks once subscription expiry plus grace period has elapsed', async()=>{
  const now=new Date('2026-10-24T00:00:00.000Z');
  const result=await workspaceBillingLock(mongooseWithGracePeriod(3),{billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}},now);
  assert.equal(result.code,'WORKSPACE_BILLING_REQUIRED');
  assert.equal(result.billing.gracePeriodDays,3);
});

test('workspace locks if setup is unpaid or expiry is missing/invalid', async()=>{
  const mongoose=mongooseWithGracePeriod();
  for(const billing of [
    {billingEnforced:true,setupFeePaid:false,subscriptionExpiresAt:'2026-12-01T00:00:00.000Z'},
    {billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:null},
    {billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'not-a-date'},
  ]) assert.equal((await workspaceBillingLock(mongoose,{billing})).code,'WORKSPACE_BILLING_REQUIRED');
});

test('invalid settings fall back to the safe three-day grace period', async()=>{
  const result=await workspaceBillingLock(mongooseWithGracePeriod(999),{billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}},new Date('2026-10-22T00:00:00.000Z'));
  assert.equal(result,null);
});


test('billing settings read failures do not silently grant workspace access', async()=>{
  const mongoose={models:{WorkspaceBillingSettings:{findOne:()=>({select:()=>({lean:async()=>{throw new Error('settings unavailable');}})})}}};
  await assert.rejects(()=>workspaceBillingLock(mongoose,{billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-12-01T00:00:00.000Z'}}),/settings unavailable/);
});


test('public marketplace visibility follows the same workspace billing grace-period rule', () => {
  const now = new Date('2026-10-24T00:00:00.000Z');
  assert.equal(isWorkspaceBillingActive({billing:{}}, 3, now), true);
  assert.equal(isWorkspaceBillingActive({billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}}, 3, now), false);
  assert.equal(isWorkspaceBillingActive({billing:{billingEnforced:true,setupFeePaid:false,subscriptionExpiresAt:'2026-12-01T00:00:00.000Z'}}, 3, now), false);
});
