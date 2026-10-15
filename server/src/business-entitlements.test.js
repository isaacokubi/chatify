import test from 'node:test';
import assert from 'node:assert/strict';
import {BUSINESS_PLAN_LIMITS, planQuotaStatus} from './business-entitlements.js';

test('plan quotas reject writes at the configured limit and allow them below it', () => {
  assert.equal(planQuotaStatus('free', 'customers', 99).allowed, true);
  assert.equal(planQuotaStatus('free', 'customers', 100).allowed, false);
  assert.equal(planQuotaStatus('business_pro', 'customers', 100).allowed, true);
  assert.equal(planQuotaStatus('unknown-plan', 'members', 3).allowed, false);
  assert.equal(BUSINESS_PLAN_LIMITS.teams.workflows, 100);
});

test('unknown quota resources fail closed instead of accidentally becoming unlimited', () => {
  assert.equal(planQuotaStatus('enterprise', 'unlisted_feature', 0).allowed, false);
});
