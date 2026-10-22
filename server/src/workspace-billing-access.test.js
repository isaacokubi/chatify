import test from 'node:test';
import assert from 'node:assert/strict';
import {workspaceBillingLock, isWorkspaceBillingActive, getWorkspaceBillingStatus} from './workspace-billing-access.js';

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


test('owner billing status locks malformed subscription dates instead of reporting ACTIVE', () => {
  const result = getWorkspaceBillingStatus({billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'not-a-date'}}, 3, new Date('2026-10-22T00:00:00.000Z'));
  assert.equal(result.locked, true);
  assert.equal(result.status, 'SUBSCRIPTION_REQUIRED');
  assert.equal(result.subscriptionExpiresAt, null);
});

test('owner billing status agrees with the route gate at expiry and during grace', () => {
  const workspace = {billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}};
  assert.equal(getWorkspaceBillingStatus(workspace, 3, new Date('2026-10-22T00:00:00.000Z')).locked, false);
  assert.equal(getWorkspaceBillingStatus(workspace, 3, new Date('2026-10-24T00:00:00.000Z')).locked, true);
});

test('owner billing status clamps invalid configured grace periods', () => {
  const result = getWorkspaceBillingStatus({billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:'2026-10-20T00:00:00.000Z'}}, 999, new Date('2026-10-22T00:00:00.000Z'));
  assert.equal(result.gracePeriodDays, 3);
  assert.equal(result.locked, false);
});


test('workspace locks at the exact subscription-expiry-plus-grace boundary', async () => {
  const expiry = '2026-10-20T00:00:00.000Z';
  const workspace = {billing:{billingEnforced:true,setupFeePaid:true,subscriptionExpiresAt:expiry}};
  const graceEnd = new Date('2026-10-23T00:00:00.000Z');
  assert.equal(await workspaceBillingLock(mongooseWithGracePeriod(3), workspace, new Date(graceEnd.getTime() - 1)), null);
  assert.equal((await workspaceBillingLock(mongooseWithGracePeriod(3), workspace, graceEnd)).code, 'WORKSPACE_BILLING_REQUIRED');
  assert.equal(isWorkspaceBillingActive(workspace, 3, new Date(graceEnd.getTime() - 1)), true);
  assert.equal(isWorkspaceBillingActive(workspace, 3, graceEnd), false);
});
