import test from 'node:test';
import assert from 'node:assert/strict';
import { applyWorkspaceBillingPayment } from './workspace-billing.js';

function billingHarness({ type = 'business', setupPaid = false, expiresAt = null, ownerMatches = true, updateMatches = true } = {}) {
  const workspace = { billing: { billingEnforced: true, setupFeePaid: setupPaid, subscriptionExpiresAt: expiresAt, status: setupPaid ? 'SUBSCRIPTION_REQUIRED' : 'SETUP_PAYMENT_REQUIRED' } };
  const storedPayment = { _id: 'payment-1', status: 'SUCCESS', billingAppliedAt: undefined };
  const Workspace = {
    findOne: () => ({ select: () => ({ lean: async () => ownerMatches ? { billing: { ...workspace.billing } } : null }) }),
    updateOne: async (_filter, update) => {
      if (!updateMatches) return { matchedCount: 0 };
      for (const [key, value] of Object.entries(update.$set || {})) {
        const path = key.split('.');
        let target = workspace;
        while (path.length > 1) {
          const part = path.shift();
          target[part] ??= {};
          target = target[part];
        }
        target[path[0]] = value;
      }
      return { matchedCount: 1 };
    }
  };
  const Payment = {
    findOneAndUpdate: async (filter, update) => {
      if (storedPayment.status !== filter.status || storedPayment.billingAppliedAt !== undefined) return null;
      storedPayment.billingAppliedAt = update.$set.billingAppliedAt;
      return { ...storedPayment };
    },
    updateOne: async (_filter, update) => {
      if (update.$unset?.billingAppliedAt) delete storedPayment.billingAppliedAt;
      return { matchedCount: 1 };
    }
  };
  const mongoose = {
    models: {
      Payment,
      [type === 'business' ? 'BusinessOrganization' : 'SchoolWorkspace']: Workspace
    }
  };
  const payment = {
    ...storedPayment,
    status: 'SUCCESS',
    billingType: 'workspace_setup',
    billingWorkspaceType: type,
    billingWorkspaceId: 'workspace-1',
    requesterId: 'owner-1'
  };
  return { mongoose, payment, workspace, storedPayment };
}

test('confirmed setup payment activates setup entitlement once', async () => {
  const h = billingHarness();
  const result = await applyWorkspaceBillingPayment(h);
  assert.equal(result.applied, true);
  assert.equal(h.workspace.billing.setupFeePaid, true);
  assert.equal(h.workspace.billing.billingEnforced, true);
  assert.ok(h.storedPayment.billingAppliedAt instanceof Date);
});

test('duplicate successful callbacks do not apply the same setup payment twice', async () => {
  const h = billingHarness();
  await applyWorkspaceBillingPayment(h);
  const duplicate = await applyWorkspaceBillingPayment(h);
  assert.equal(duplicate.duplicate, true);
  assert.equal(h.workspace.billing.setupFeePaid, true);
});

test('confirmed monthly payment extends the subscription by one month', async () => {
  const h = billingHarness({ setupPaid: true, expiresAt: new Date('2026-11-01T00:00:00.000Z') });
  h.payment.billingType = 'workspace_subscription';
  const result = await applyWorkspaceBillingPayment(h);
  assert.equal(result.applied, true);
  assert.equal(h.workspace.billing.status, 'ACTIVE');
  assert.equal(new Date(h.workspace.billing.subscriptionExpiresAt).toISOString(), '2026-12-01T00:00:00.000Z');
});

test('a failed entitlement write releases the payment claim for safe callback retry', async () => {
  const h = billingHarness({ ownerMatches: false });
  await assert.rejects(() => applyWorkspaceBillingPayment(h), /owner did not match/);
  assert.equal(h.storedPayment.billingAppliedAt, undefined);
});

test('subscription payment cannot activate before setup has been paid', async () => {
  const h = billingHarness({ setupPaid: false });
  h.payment.billingType = 'workspace_subscription';
  await assert.rejects(() => applyWorkspaceBillingPayment(h), /setup fee must be paid/);
  assert.equal(h.storedPayment.billingAppliedAt, undefined);
});
