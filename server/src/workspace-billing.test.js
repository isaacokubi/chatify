import test from 'node:test';
import assert from 'node:assert/strict';
import { applyWorkspaceBillingPayment, assessPendingWorkspaceBillingPayment } from './workspace-billing.js';

function billingHarness({ type = 'business', setupPaid = false, expiresAt = null, ownerMatches = true, updateMatches = true, paymentMarkFailures = 0 } = {}) {
  const workspace = { billing: { billingEnforced: true, setupFeePaid: setupPaid, subscriptionExpiresAt: expiresAt, status: setupPaid ? 'SUBSCRIPTION_REQUIRED' : 'SETUP_PAYMENT_REQUIRED', appliedPaymentIds: [] } };
  const storedPayment = { _id: 'payment-1', paymentId: 'payment-1', status: 'SUCCESS', billingAppliedAt: undefined };
  let remainingPaymentMarkFailures = paymentMarkFailures;
  const Workspace = {
    findOne: (filter) => ({ select: () => ({ lean: async () => {
      if (!ownerMatches) return null;
      if (filter?.['billing.appliedPaymentIds']?.$ne && workspace.billing.appliedPaymentIds.includes(filter['billing.appliedPaymentIds'].$ne)) return null;
      return { billing: { ...workspace.billing, appliedPaymentIds: [...workspace.billing.appliedPaymentIds] } };
    } }) }),
    updateOne: async (filter, update) => {
      if (!updateMatches || !ownerMatches) return { matchedCount: 0 };
      const excludedPayment = filter?.['billing.appliedPaymentIds']?.$ne;
      if (excludedPayment && workspace.billing.appliedPaymentIds.includes(excludedPayment)) return { matchedCount: 0 };
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
      for (const [key, value] of Object.entries(update.$addToSet || {})) {
        const path = key.split('.');
        let target = workspace;
        while (path.length > 1) {
          const part = path.shift();
          target[part] ??= {};
          target = target[part];
        }
        target[path[0]] ??= [];
        if (!target[path[0]].includes(value)) target[path[0]].push(value);
      }
      return { matchedCount: 1 };
    }
  };
  const Payment = {
    updateOne: async (_filter, update) => {
      if (update.$set?.billingAppliedAt && remainingPaymentMarkFailures > 0) {
        remainingPaymentMarkFailures -= 1;
        throw new Error('simulated payment marker write failure');
      }
      if (update.$set?.billingAppliedAt) storedPayment.billingAppliedAt = update.$set.billingAppliedAt;
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
    paymentId: 'payment-1',
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

test('retry after workspace update but before payment marker does not extend subscription twice', async () => {
  const h = billingHarness({ setupPaid: true, expiresAt: new Date('2026-11-01T00:00:00.000Z'), paymentMarkFailures: 1 });
  h.payment.billingType = 'workspace_subscription';
  await assert.rejects(() => applyWorkspaceBillingPayment(h), /simulated payment marker write failure/);
  assert.equal(new Date(h.workspace.billing.subscriptionExpiresAt).toISOString(), '2026-12-01T00:00:00.000Z');
  const retry = await applyWorkspaceBillingPayment(h);
  assert.equal(retry.duplicate, true);
  assert.equal(new Date(h.workspace.billing.subscriptionExpiresAt).toISOString(), '2026-12-01T00:00:00.000Z');
  assert.ok(h.storedPayment.billingAppliedAt instanceof Date);
});

test('subscription payment cannot activate before setup has been paid', async () => {
  const h = billingHarness({ setupPaid: false });
  h.payment.billingType = 'workspace_subscription';
  await assert.rejects(() => applyWorkspaceBillingPayment(h), /setup fee must be paid/);
  assert.equal(h.storedPayment.billingAppliedAt, undefined);
});


test('workspace checkout reuses a pending payment only when its price still matches', () => {
  const pending = {paymentId:'payment-2',amount:500,status:'PENDING',billingType:'workspace_subscription',initiatedAt:null};
  assert.equal(assessPendingWorkspaceBillingPayment(null,500).action,'create');
  assert.equal(assessPendingWorkspaceBillingPayment(pending,500).action,'reuse');
  const changed = assessPendingWorkspaceBillingPayment(pending,750);
  assert.equal(changed.action,'conflict');
  assert.equal(changed.code,'WORKSPACE_BILLING_PRICE_CHANGED_PENDING');
  assert.equal(changed.payment.amount,500);
});

test('monthly renewal preserves calendar month-end dates without overflowing into March', async () => {
  const h = billingHarness({ setupPaid: true, expiresAt: new Date('2027-01-31T00:00:00.000Z') });
  h.payment.billingType = 'workspace_subscription';
  const result = await applyWorkspaceBillingPayment(h);
  assert.equal(result.applied, true);
  assert.equal(new Date(h.workspace.billing.subscriptionExpiresAt).toISOString(), '2027-02-28T00:00:00.000Z');
});
test('month-end renewals remain at month end across short and leap-year February', async () => {
  for (const [expiry, expected] of [
    ['2027-02-28T00:00:00.000Z', '2027-03-31T00:00:00.000Z'],
    ['2028-02-29T00:00:00.000Z', '2028-03-31T00:00:00.000Z'],
  ]) {
    const h = billingHarness({ setupPaid: true, expiresAt: new Date(expiry) });
    h.payment.billingType = 'workspace_subscription';
    const result = await applyWorkspaceBillingPayment(h);
    assert.equal(result.applied, true, `renewal from ${expiry} should apply`);
    assert.equal(new Date(h.workspace.billing.subscriptionExpiresAt).toISOString(), expected);
  }
});


test('reconciliation selects only successful unapplied workspace billing payments and applies them idempotently', async () => {
  const h = billingHarness();
  const selected = [
    { ...h.payment, paymentId: 'payment-1', status: 'SUCCESS', billingType: 'workspace_setup', billingWorkspaceId: 'workspace-1' },
  ];
  const query = {
    sort(sort) { assert.deepEqual(sort, { completedAt: 1, _id: 1 }); return this; },
    limit(limit) { assert.equal(limit, 25); return Promise.resolve(selected); },
  };
  const Payment = { find(filter) {
    assert.equal(filter.status, 'SUCCESS');
    assert.deepEqual(filter.billingType.$in, ['workspace_setup', 'workspace_subscription']);
    assert.deepEqual(filter.billingAppliedAt.$in, [null]);
    return query;
  }};
  const { reconcileWorkspaceBillingPayments } = await import('./workspace-billing.js');
  const result = await reconcileWorkspaceBillingPayments({ mongoose: h.mongoose, Payment, limit: 25 });
  assert.equal(result.scanned, 1);
  assert.equal(result.applied, 1);
  assert.equal(result.failed, 0);
  assert.equal(h.workspace.billing.setupFeePaid, true);
});

test('reconciliation caps batches and reports failures without exposing exception text', async () => {
  const { reconcileWorkspaceBillingPayments } = await import('./workspace-billing.js');
  const query = {
    sort() { return this; },
    limit(limit) { assert.equal(limit, 500); return Promise.resolve([{ paymentId: 'bad-payment' }]); },
  };
  const result = await reconcileWorkspaceBillingPayments({
    mongoose: { models: {} },
    Payment: { find: () => query },
    limit: 10000,
  });
  assert.equal(result.scanned, 1);
  assert.equal(result.failed, 1);
  assert.deepEqual(result.failures, [{ paymentId: 'bad-payment', reason: 'ENTITLEMENT_RECONCILIATION_FAILED' }]);
});
