// Workspace setup and recurring subscription billing.
// Uses the existing Payment lifecycle so STK prompts, idempotency and Safaricom callbacks
// continue through the same payment state machine as the rest of Chatify.
import { newPaymentId } from './payments.js';

const monthFrom = value => {
  const start = new Date(value);
  const day = start.getUTCDate();
  start.setUTCMonth(start.getUTCMonth() + 1);
  // Avoid JavaScript's month-end rollover (e.g. Jan 31 becoming Mar 3).
  if (start.getUTCDate() < day) start.setUTCDate(0);
  return start;
};

export async function applyWorkspaceBillingPayment({ mongoose, payment }) {
  if (!payment?.billingType || !payment?.billingWorkspaceId || payment.status !== 'SUCCESS') return { applied: false };
  // Atomically claim each successful billing payment so duplicate Safaricom callbacks
  // cannot extend a subscription more than once.
  let claimedPayment = null;
  if (payment._id && mongoose.models.Payment) {
    claimedPayment = await mongoose.models.Payment.findOneAndUpdate({_id: payment._id, status: 'SUCCESS', billingAppliedAt: {$exists: false}}, {$set: {billingAppliedAt: new Date()}}, {new: true});
    if (!claimedPayment) return {applied: false, duplicate: true};
  }
  const modelName = payment.billingWorkspaceType === 'business' ? 'BusinessOrganization'
    : payment.billingWorkspaceType === 'school' ? 'SchoolWorkspace' : null;
  if (!modelName || !mongoose.models[modelName]) throw new Error('Billing workspace model is unavailable');
  const Model = mongoose.models[modelName];
  const id = payment.billingWorkspaceId;
  const ownerField = payment.billingWorkspaceType === 'business' ? 'ownerId' : 'createdBy';
  const workspace = await Model.findOne({ _id: id, [ownerField]: payment.requesterId }).select('billing').lean();
  if (!workspace) { if (claimedPayment) await mongoose.models.Payment.updateOne({_id: claimedPayment._id, billingAppliedAt: claimedPayment.billingAppliedAt}, {$unset: {billingAppliedAt: 1}}); throw new Error('Billing workspace owner did not match the payment requester'); }
  const billing = workspace.billing || {};
  if (payment.billingType === 'workspace_setup') {
    await Model.updateOne({ _id: id, [ownerField]: payment.requesterId }, {
      $set: { 'billing.billingEnforced': true, 'billing.setupFeePaid': true, 'billing.status': billing.subscriptionExpiresAt && new Date(billing.subscriptionExpiresAt) > new Date() ? 'ACTIVE' : 'SUBSCRIPTION_REQUIRED' }
    });
    return { applied: true, billingType: payment.billingType };
  }
  if (payment.billingType === 'workspace_subscription') {
    if (!billing.setupFeePaid) { if (claimedPayment) await mongoose.models.Payment.updateOne({_id: claimedPayment._id, billingAppliedAt: claimedPayment.billingAppliedAt}, {$unset: {billingAppliedAt: 1}}); throw new Error('Workspace setup fee must be paid before subscription activation'); }
    const now = new Date();
    const expiry = billing.subscriptionExpiresAt && new Date(billing.subscriptionExpiresAt) > now
      ? monthFrom(billing.subscriptionExpiresAt) : monthFrom(now);
    await Model.updateOne({ _id: id, [ownerField]: payment.requesterId }, {
      $set: { 'billing.billingEnforced': true, 'billing.subscriptionExpiresAt': expiry, 'billing.status': 'ACTIVE' }
    });
    return { applied: true, billingType: payment.billingType, subscriptionExpiresAt: expiry };
  }
  return { applied: false };
}

export function registerWorkspaceBillingRoutes({ app, auth, mongoose, Payment, mpesaProvider }) {
  const O = mongoose.Schema.Types.ObjectId;
  const Settings = mongoose.models.WorkspaceBillingSettings || mongoose.model('WorkspaceBillingSettings', new mongoose.Schema({
    key: { type: String, unique: true, default: 'global' },
    businessSetupFee: { type: Number, min: 0, max: 1000000, default: 1000 },
    businessMonthlyFee: { type: Number, min: 0, max: 1000000, default: 500 },
    schoolSetupFee: { type: Number, min: 0, max: 1000000, default: 5000 },
    schoolMonthlyFee: { type: Number, min: 0, max: 1000000, default: 2500 },
    gracePeriodDays: { type: Number, min: 0, max: 30, default: 3 },
    updatedBy: { type: O, default: null }
  }, { timestamps: true }));

  const adminOnly = (req, res) => {
    if (req.user?.role !== 'admin') { res.status(403).json({ error: 'Administrator permission required' }); return false; }
    return true;
  };
  const findWorkspace = async (type, id, userId) => {
    if (!mongoose.isValidObjectId(id)) return null;
    const modelName = type === 'business' ? 'BusinessOrganization' : type === 'school' ? 'SchoolWorkspace' : null;
    if (!modelName || !mongoose.models[modelName]) return null;
    const Model = mongoose.models[modelName];
    const ownerField = type === 'business' ? 'ownerId' : 'createdBy';
    const workspace = await Model.findOne({ _id: id, [ownerField]: userId }).select('name code billing').lean();
    return workspace ? { ...workspace, type, modelName, ownerField } : null;
  };

  app.get('/api/admin/workspace-billing-settings', auth, async (req, res) => {
    if (!adminOnly(req, res)) return;
    const settings = await Settings.findOne({ key: 'global' }).lean();
    res.json({ settings: settings || { businessSetupFee: 1000, businessMonthlyFee: 500, schoolSetupFee: 5000, schoolMonthlyFee: 2500, gracePeriodDays: 3 } });
  });
  app.put('/api/admin/workspace-billing-settings', auth, async (req, res) => {
    if (!adminOnly(req, res)) return;
    const body = req.body || {};
    const fields = ['businessSetupFee', 'businessMonthlyFee', 'schoolSetupFee', 'schoolMonthlyFee'];
    const values = {};
    for (const field of fields) {
      const amount = Number(body[field]);
      if (!Number.isSafeInteger(amount) || amount < 0 || amount > 1000000) return res.status(400).json({ error: field + ' must be a whole KSh amount from 0 to 1,000,000' });
      values[field] = amount;
    }
    const gracePeriodDays = Number(body.gracePeriodDays);
    if (!Number.isInteger(gracePeriodDays) || gracePeriodDays < 0 || gracePeriodDays > 30) return res.status(400).json({ error: 'gracePeriodDays must be between 0 and 30' });
    values.gracePeriodDays = gracePeriodDays;
    values.updatedBy = req.user._id;
    const settings = await Settings.findOneAndUpdate({ key: 'global' }, { $set: values }, { upsert: true, new: true, runValidators: true, setDefaultsOnInsert: true });
    res.json({ settings });
  });

  app.get('/api/workspace-billing/:type/:workspaceId', auth, async (req, res) => {
    const workspace = await findWorkspace(req.params.type, req.params.workspaceId, req.user._id);
    if (!workspace) return res.status(404).json({ error: 'Workspace not found or you are not its owner' });
    const settings = await Settings.findOne({ key: 'global' }).lean() || {};
    const billing = workspace.billing || {};
    const expiresAt = billing.subscriptionExpiresAt ? new Date(billing.subscriptionExpiresAt) : null;
    const graceDays = Number(settings.gracePeriodDays ?? 3);
    const graceEnd = expiresAt ? new Date(expiresAt.getTime() + graceDays * 86400000) : null;
    const locked = billing.billingEnforced === true && (!billing.setupFeePaid || !expiresAt || graceEnd <= new Date());
    res.json({ workspace: { id: String(workspace._id), name: workspace.name, type: workspace.type }, billing: {
      setupFeePaid: Boolean(billing.setupFeePaid), subscriptionExpiresAt: expiresAt,
      status: !billing.billingEnforced ? 'LEGACY_GRANDFATHERED' : locked ? (!billing.setupFeePaid ? 'SETUP_PAYMENT_REQUIRED' : 'SUBSCRIPTION_EXPIRED') : 'ACTIVE',
      locked, gracePeriodDays: graceDays,
      prices: { setupFee: Number(settings[workspace.type + 'SetupFee'] ?? (workspace.type === 'business' ? 1000 : 5000)), monthlyFee: Number(settings[workspace.type + 'MonthlyFee'] ?? (workspace.type === 'business' ? 500 : 2500)) }
    }});
  });

  app.post('/api/workspace-billing/:type/:workspaceId/checkout', auth, async (req, res) => {
    const workspace = await findWorkspace(req.params.type, req.params.workspaceId, req.user._id);
    if (!workspace) return res.status(404).json({ error: 'Workspace not found or you are not its owner' });
    const type = String(req.body?.billingType || '');
    if (!['workspace_setup', 'workspace_subscription'].includes(type)) return res.status(400).json({ error: 'billingType must be workspace_setup or workspace_subscription' });
    const billing = workspace.billing || {};
    if (type === 'workspace_setup' && billing.setupFeePaid) return res.status(409).json({ error: 'The one-time workspace setup fee has already been paid' });
    if (type === 'workspace_subscription' && !billing.setupFeePaid) return res.status(409).json({ error: 'Pay the one-time setup fee before purchasing a monthly subscription' });
    const settings = await Settings.findOne({ key: 'global' }).lean() || {};
    const priceField = workspace.type + (type === 'workspace_setup' ? 'SetupFee' : 'MonthlyFee');
    const fallback = workspace.type === 'business' ? (type === 'workspace_setup' ? 1000 : 500) : (type === 'workspace_setup' ? 5000 : 2500);
    const amount = Number(settings[priceField] ?? fallback);
    if (!Number.isSafeInteger(amount) || amount < 0) return res.status(503).json({ error: 'Workspace billing price is not configured correctly' });
    if (amount === 0) {
      const payment = { status: 'SUCCESS', billingType: type, billingWorkspaceType: workspace.type, billingWorkspaceId: workspace._id, requesterId: req.user._id };
      await applyWorkspaceBillingPayment({ mongoose, payment });
      return res.json({ paid: true, amount: 0, notice: 'This workspace billing item is free under the current administrator pricing.' });
    }
    const payment = await Payment.create({
      paymentId: newPaymentId(), requesterId: req.user._id, payerId: req.user._id,
      amount, baseAmount: amount, platformFee: 0, totalAmount: amount, platformFeeRate: 0,
      platformFeeStatus: 'NOT_APPLICABLE', feeCollectionMode: 'separate',
      billingType: type, billingWorkspaceType: workspace.type, billingWorkspaceId: workspace._id,
      description: type === 'workspace_setup' ? 'Chatify workspace setup' : 'Chatify monthly subscription',
      purpose: 'SELF_STK', provider: mpesaProvider.name, requestedAt: new Date()
    });
    res.status(201).json({ payment: { paymentId: payment.paymentId, amount: payment.amount, status: payment.status, billingType: payment.billingType }, next: 'Call POST /api/payments/' + payment.paymentId + '/initiate with the payer phone to send the M-Pesa prompt.' });
  });
}
