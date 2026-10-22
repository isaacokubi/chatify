// Workspace setup and recurring subscription billing.
// Uses the existing Payment lifecycle so STK prompts, idempotency and Safaricom callbacks
// continue through the same payment state machine as the rest of Chatify.
import { newPaymentId } from './payments.js';
import { getWorkspaceBillingStatus } from './workspace-billing-access.js';

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
  if (!['workspace_setup', 'workspace_subscription'].includes(payment.billingType)) return { applied: false };
  if (!payment.paymentId) throw new Error('A stable payment ID is required for workspace billing idempotency');
  const modelName = payment.billingWorkspaceType === 'business' ? 'BusinessOrganization'
    : payment.billingWorkspaceType === 'school' ? 'SchoolWorkspace' : null;
  if (!modelName || !mongoose.models[modelName]) throw new Error('Billing workspace model is unavailable');

  const Model = mongoose.models[modelName];
  const id = payment.billingWorkspaceId;
  const ownerField = payment.billingWorkspaceType === 'business' ? 'ownerId' : 'createdBy';
  const ownerFilter = { _id: id, [ownerField]: payment.requesterId };
  const workspace = await Model.findOne(ownerFilter).select('billing').lean();
  if (!workspace) throw new Error('Billing workspace owner did not match the payment requester');

  const billing = workspace.billing || {};
  const appliedIds = Array.isArray(billing.appliedPaymentIds) ? billing.appliedPaymentIds.map(String) : [];
  if (appliedIds.includes(String(payment.paymentId))) {
    if (payment._id && mongoose.models.Payment) {
      await mongoose.models.Payment.updateOne({ _id: payment._id, status: 'SUCCESS' }, { $set: { billingAppliedAt: new Date() } });
    }
    return { applied: false, duplicate: true, alreadyApplied: true };
  }

  let update;
  let result;
  if (payment.billingType === 'workspace_setup') {
    update = {
      $set: {
        'billing.billingEnforced': true,
        'billing.setupFeePaid': true,
        'billing.status': billing.subscriptionExpiresAt && new Date(billing.subscriptionExpiresAt) > new Date()
          ? 'ACTIVE' : 'SUBSCRIPTION_REQUIRED'
      },
      $addToSet: { 'billing.appliedPaymentIds': String(payment.paymentId) }
    };
    result = await Model.updateOne({ ...ownerFilter, 'billing.appliedPaymentIds': { $ne: String(payment.paymentId) } }, update);
  } else {
    if (!billing.setupFeePaid) throw new Error('Workspace setup fee must be paid before subscription activation');
    const now = new Date();
    const expiry = billing.subscriptionExpiresAt && new Date(billing.subscriptionExpiresAt) > now
      ? monthFrom(billing.subscriptionExpiresAt) : monthFrom(now);
    update = {
      $set: {
        'billing.billingEnforced': true,
        'billing.subscriptionExpiresAt': expiry,
        'billing.status': 'ACTIVE'
      },
      $addToSet: { 'billing.appliedPaymentIds': String(payment.paymentId) }
    };
    result = await Model.updateOne({ ...ownerFilter, 'billing.appliedPaymentIds': { $ne: String(payment.paymentId) } }, update);
  }

  // The workspace update is the idempotency boundary. If the process crashes after
  // this write but before the payment marker, a retry sees appliedPaymentIds and
  // safely repairs the marker without extending the subscription again.
  if (!result.matchedCount) {
    const current = await Model.findOne(ownerFilter).select('billing').lean();
    if (current?.billing?.appliedPaymentIds?.map(String).includes(String(payment.paymentId))) {
      if (payment._id && mongoose.models.Payment) {
        await mongoose.models.Payment.updateOne({ _id: payment._id, status: 'SUCCESS' }, { $set: { billingAppliedAt: new Date() } });
      }
      return { applied: false, duplicate: true, alreadyApplied: true };
    }
    throw new Error('Workspace billing update did not match a workspace');
  }

  if (payment._id && mongoose.models.Payment) {
    await mongoose.models.Payment.updateOne({ _id: payment._id, status: 'SUCCESS' }, { $set: { billingAppliedAt: new Date() } });
  }
  return {
    applied: true,
    billingType: payment.billingType,
    ...(payment.billingType === 'workspace_subscription' ? { subscriptionExpiresAt: update.$set['billing.subscriptionExpiresAt'] } : {})
  };
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
    const billingStatus = getWorkspaceBillingStatus(workspace, Number(settings.gracePeriodDays ?? 3));
    res.json({ workspace: { id: String(workspace._id), name: workspace.name, type: workspace.type }, billing: {
      ...billingStatus,
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
      const freePeriod = type === 'workspace_subscription' ? new Date().toISOString().slice(0, 7) : 'once';
      const payment = { paymentId: 'free-' + type + '-' + String(workspace._id) + '-' + freePeriod, status: 'SUCCESS', billingType: type, billingWorkspaceType: workspace.type, billingWorkspaceId: workspace._id, requesterId: req.user._id };
      await applyWorkspaceBillingPayment({ mongoose, payment });
      return res.json({ paid: true, amount: 0, notice: 'This workspace billing item is free under the current administrator pricing.' });
    }
    // Reuse an unfinished billing payment rather than creating multiple STK prompts
    // when a customer retries the screen or a mobile request times out.
    const pending = await Payment.findOne({
      requesterId: req.user._id,
      billingType: type,
      billingWorkspaceType: workspace.type,
      billingWorkspaceId: workspace._id,
      status: 'PENDING',
      billingAppliedAt: { $exists: false }
    }).sort({ createdAt: -1 });
    if (pending) {
      return res.status(200).json({ payment: {
        paymentId: pending.paymentId,
        amount: pending.amount,
        status: pending.status,
        billingType: pending.billingType,
        initiatedAt: pending.initiatedAt || null
      }, reused: true });
    }
    const payment = await Payment.create({
      paymentId: newPaymentId(), requesterId: req.user._id, payerId: req.user._id,
      amount, baseAmount: amount, platformFee: 0, totalAmount: amount, platformFeeRate: 0,
      platformFeeStatus: 'NOT_APPLICABLE', feeCollectionMode: 'separate',
      billingType: type, billingWorkspaceType: workspace.type, billingWorkspaceId: workspace._id,
      description: type === 'workspace_setup' ? 'Chatify workspace setup' : 'Chatify monthly subscription',
      purpose: 'SELF_STK', provider: mpesaProvider.name, requestedAt: new Date()
    });
    res.status(201).json({ payment: { paymentId: payment.paymentId, amount: payment.amount, status: payment.status, billingType: payment.billingType, initiatedAt: payment.initiatedAt || null }, next: 'Call POST /api/payments/' + payment.paymentId + '/initiate with the payer phone to send the M-Pesa prompt.' });
  });
}
