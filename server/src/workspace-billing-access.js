// Shared server-side gate for business routes outside the core Business router.
// Billing is enforced only for workspaces explicitly marked by the subscription rollout;
// older workspaces remain grandfathered in. Billing endpoints themselves must stay reachable.
export function getWorkspaceBillingStatus(workspace, gracePeriodDays = 3, now = new Date()) {
  const billing = workspace?.billing || {};
  const enforced = billing.billingEnforced === true;
  const graceDays = Number.isInteger(gracePeriodDays) && gracePeriodDays >= 0 && gracePeriodDays <= 30
    ? gracePeriodDays : 3;
  const rawExpiry = billing.subscriptionExpiresAt;
  const expiresAt = rawExpiry ? new Date(rawExpiry) : null;
  const validExpiry = Boolean(expiresAt && Number.isFinite(expiresAt.getTime()));
  const graceEnd = validExpiry ? new Date(expiresAt.getTime() + graceDays * 86400000) : null;
  const locked = enforced && (
    billing.setupFeePaid !== true ||
    !validExpiry ||
    graceEnd <= now
  );
  const status = !enforced ? 'LEGACY_GRANDFATHERED'
    : billing.setupFeePaid !== true ? 'SETUP_PAYMENT_REQUIRED'
      : !validExpiry ? 'SUBSCRIPTION_REQUIRED'
        : locked ? 'SUBSCRIPTION_EXPIRED' : 'ACTIVE';
  return {
    status,
    locked,
    setupFeePaid: billing.setupFeePaid === true,
    subscriptionExpiresAt: validExpiry ? expiresAt : null,
    gracePeriodDays: graceDays,
  };
}

export function isWorkspaceBillingActive(workspace, gracePeriodDays = 3, now = new Date()) {
  const billing = workspace?.billing;
  if (billing?.billingEnforced !== true) return true;
  const graceDays = Number.isInteger(gracePeriodDays) && gracePeriodDays >= 0 && gracePeriodDays <= 30
    ? gracePeriodDays : 3;
  const expiresAt = billing.subscriptionExpiresAt ? new Date(billing.subscriptionExpiresAt) : null;
  return billing.setupFeePaid === true &&
    Boolean(expiresAt && Number.isFinite(expiresAt.getTime())) &&
    new Date(expiresAt.getTime() + graceDays * 86400000) > now;
}

export async function workspaceBillingLock(mongoose, workspace, now = new Date()) {
  const billing = workspace?.billing;
  if (billing?.billingEnforced !== true) return null;

  let configuredGraceDays = 3;
  const settings = await mongoose.models.WorkspaceBillingSettings
    ?.findOne({ key: 'global' }).select('gracePeriodDays').lean();
  const candidate = Number(settings?.gracePeriodDays ?? 3);
  if (Number.isInteger(candidate) && candidate >= 0 && candidate <= 30) {
    configuredGraceDays = candidate;
  }

  const expiresAt = billing.subscriptionExpiresAt ? new Date(billing.subscriptionExpiresAt) : null;
  const validExpiry = expiresAt && Number.isFinite(expiresAt.getTime());
  const lockAt = validExpiry ? new Date(expiresAt.getTime() + configuredGraceDays * 86400000) : null;
  if (billing.setupFeePaid === true && lockAt && lockAt > now) return null;

  return {
    error: 'This workspace is locked because its setup fee or monthly subscription is unpaid or expired.',
    code: 'WORKSPACE_BILLING_REQUIRED',
    billing: {
      setupFeePaid: billing.setupFeePaid === true,
      subscriptionExpiresAt: validExpiry ? expiresAt : null,
      gracePeriodDays: configuredGraceDays,
    },
  };
}

// Return true when the response has been completed and the caller must stop.
export async function rejectLockedWorkspace(mongoose, workspace, res) {
  const lock = await workspaceBillingLock(mongoose, workspace);
  if (!lock) return false;
  res.status(402).json(lock);
  return true;
}
