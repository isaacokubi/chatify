// Shared server-side SaaS entitlements. Limits are shared by UI and write paths.
export const BUSINESS_PLAN_LIMITS = Object.freeze({
  free: Object.freeze({members: 3, customers: 100, catalogItems: 100, documents: 250, enterpriseRecords: 100, branches: 1, workflows: 2}),
  business_pro: Object.freeze({members: 10, customers: 2000, catalogItems: 1000, documents: 5000, enterpriseRecords: 2500, branches: 5, workflows: 20}),
  teams: Object.freeze({members: 50, customers: 20000, catalogItems: 10000, documents: 50000, enterpriseRecords: 20000, branches: 50, workflows: 100}),
  enterprise: Object.freeze({members: 1000, customers: 1000000, catalogItems: 1000000, documents: 1000000, enterpriseRecords: 1000000, branches: 1000, workflows: 1000}),
});

export function planQuotaStatus(planName, resource, currentUsage) {
  const plan = Object.hasOwn(BUSINESS_PLAN_LIMITS, planName) ? planName : 'free';
  const limit = BUSINESS_PLAN_LIMITS[plan][resource];
  if (!Number.isFinite(limit)) return {allowed: false, plan, resource, limit: 0};
  const usage = Number.isFinite(currentUsage) && currentUsage >= 0 ? currentUsage : 0;
  return {allowed: usage < limit, plan, resource, limit, usage, remaining: Math.max(0, limit - usage)};
}
