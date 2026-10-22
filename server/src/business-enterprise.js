import {createHash, randomBytes} from 'node:crypto';
import {rejectLockedWorkspace} from './workspace-billing-access.js';
import {BUSINESS_PLAN_LIMITS, planQuotaStatus} from './business-entitlements.js';

// CHATIFY BUSINESS ENTERPRISE EXTENSIONS
// This module adds organization-scoped workflows on top of the existing Business models.
// It intentionally keeps financial outcomes provider-verified and uses one tenant boundary
// for every record, search result, approval, acknowledgement, and support incident.
const RECORD_TYPES = Object.freeze([
  'handbook', 'notification', 'approval', 'refund_case', 'credit_profile',
  'project_room', 'supplier_quote', 'service_policy', 'delivery_proof',
  'dispute', 'consent_record', 'support_case', 'incident', 'integration',
  'migration_job', 'recovery_plan', 'promise', 'response_target', 'subscription_note',
  'financial_close', 'supplier_comparison', 'customer_portal', 'reputation_review', 'service_recovery',
]);
const STATUSES = Object.freeze([
  'draft', 'open', 'pending', 'approved', 'rejected', 'in_progress',
  'waiting', 'resolved', 'closed', 'cancelled', 'acknowledged',
]);
const PRIORITIES = Object.freeze(['low', 'normal', 'high', 'urgent']);
const textValue = (value, max = 2000) => typeof value === 'string' ? value.trim().slice(0, max) : '';
const validDate = value => value == null || value === '' ? undefined : (Number.isNaN(new Date(value).getTime()) ? null : new Date(value));

export function extractPromiseSuggestions(source = '') {
  // This is a deterministic suggestion, not an AI assertion: a human must confirm it.
  const text = textValue(source, 5000);
  const patterns = [
    /(?:i(?:'| wi)?ll|we(?:'| wi)?ll|will)\s+(?:deliver|send|finish|complete|call|pay|refund|ship|prepare|provide)\b[^.!?]{0,180}/ig,
    /(?:by|before|on)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?)\b/ig,
  ];
  const matches = new Set();
  for (const pattern of patterns) for (const match of text.matchAll(pattern)) {
    const candidate = match[0].trim().replace(/\s+/g, ' ');
    if (candidate.length >= 8) matches.add(candidate.slice(0, 220));
  }
  return [...matches].slice(0, 10).map(suggestion => ({
    suggestion, confirmed: false,
    notice: 'Suggestion only. Confirm the wording, owner and due date before creating a commitment.',
  }));
}

export function normalizeEnterpriseRecord(input = {}) {
  const type = String(input.type || '');
  if (!RECORD_TYPES.includes(type)) throw new Error('Unsupported business record type');
  const title = textValue(input.title, 200);
  if (!title) throw new Error('A title is required');
  const status = STATUSES.includes(input.status) ? input.status : 'open';
  const priority = PRIORITIES.includes(input.priority) ? input.priority : 'normal';
  const dueAt = validDate(input.dueAt);
  if (dueAt === null) throw new Error('Invalid due date');
  if (input.assignedTo && !/^[a-f\d]{24}$/i.test(String(input.assignedTo))) throw new Error('Invalid assignee');
  const payload = input.payload && typeof input.payload === 'object' && !Array.isArray(input.payload) ? input.payload : {};
  return {
    type, title, description: textValue(input.description, 6000), status, priority,
    ...(dueAt ? {dueAt} : {}),
    assignedTo: input.assignedTo || undefined,
    payload,
  };
}

export function registerBusinessEnterpriseRoutes({app, auth, mongoose}) {
  // Existing Business routes register first and define these tenant models.
  const Organization = mongoose.models.BusinessOrganization;
  const Customer = mongoose.models.BusinessCustomer;
  const CatalogItem = mongoose.models.BusinessCatalogItem;
  const BusinessDocument = mongoose.models.BusinessDocument;
  const BusinessTask = mongoose.models.BusinessTask;
  const BusinessCase = mongoose.models.BusinessCase;
  const O = mongoose.Schema.Types.ObjectId;
  const EnterpriseRecord = mongoose.models.BusinessEnterpriseRecord || mongoose.model(
    'BusinessEnterpriseRecord',
    new mongoose.Schema({
      organizationId: {type: O, required: true, index: true},
      type: {type: String, enum: RECORD_TYPES, required: true, index: true},
      title: {type: String, required: true, maxlength: 200},
      description: {type: String, maxlength: 6000, default: ''},
      status: {type: String, enum: STATUSES, default: 'open', index: true},
      priority: {type: String, enum: PRIORITIES, default: 'normal'},
      dueAt: Date, assignedTo: O,
      payload: {type: mongoose.Schema.Types.Mixed, default: {}},
      acknowledgements: {type: [{userId: O, acknowledgedAt: Date}], default: []},
      approvals: {type: [{userId: O, decision: {type: String, enum: ['approved', 'rejected']}, reason: String, decidedAt: Date}], default: []},
      createdBy: {type: O, required: true},
      updatedBy: O,
      resolvedAt: Date,
    }, {timestamps: true}),
  );
  EnterpriseRecord.schema.index({organizationId: 1, type: 1, status: 1, updatedAt: -1});
  EnterpriseRecord.schema.index({organizationId: 1, title: 'text', description: 'text'});

  // Public links store only a hash of a high-entropy token. Revocation and expiry are server-enforced.
  const ExternalShare = mongoose.models.BusinessExternalShare || mongoose.model('BusinessExternalShare', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true},
    entityType: {type: String, enum: ['document', 'enterprise_record'], required: true},
    entityId: {type: String, required: true},
    tokenHash: {type: String, required: true, unique: true, select: false},
    createdBy: {type: O, required: true},
    expiresAt: {type: Date, required: true, index: true},
    revokedAt: Date,
    accessCount: {type: Number, default: 0},
    lastAccessAt: Date,
  }, {timestamps: true}));


  const getOrg = async (req, res) => {
    if (!Organization || !mongoose.isValidObjectId(req.params.orgId)) {
      res.status(404).json({error: 'Business workspace not found'}); return null;
    }
    const org = await Organization.findOne({
      _id: req.params.orgId,
      $or: [{ownerId: req.user._id}, {'members.userId': req.user._id}],
    });
    if (!org) { res.status(404).json({error: 'Business workspace not found'}); return null; }
    if (await rejectLockedWorkspace(mongoose, org, res)) return null;
    const member = (org.members || []).find(item => String(item.userId) === String(req.user._id));
    req.businessEnterpriseRole = String(org.ownerId) === String(req.user._id) ? 'owner' : (member?.role || 'viewer');
    return org;
  };
  const canWrite = (req, res) => {
    if (['owner', 'admin', 'manager', 'sales', 'finance', 'support', 'fulfilment'].includes(req.businessEnterpriseRole)) return true;
    res.status(403).json({error: 'This business role cannot change enterprise records'}); return false;
  };
  const canApprove = (req, res) => {
    if (['owner', 'admin', 'manager', 'finance'].includes(req.businessEnterpriseRole)) return true;
    res.status(403).json({error: 'Manager or finance approval is required'}); return false;
  };
  const audit = async (org, req, action, record, summary) => {
    const Audit = mongoose.models.BusinessAudit;
    if (!Audit) return;
    await Audit.create({
      organizationId: org._id, actorId: req.user._id, action,
      entityType: 'enterprise_record', entityId: String(record._id),
      summary: textValue(summary, 300), occurredAt: new Date(),
    });
  };
  const base = '/api/business/organizations/:orgId/enterprise';


  app.get('/api/business/public-shares/:token', async (req, res) => {
    const token = String(req.params.token || '');
    if (!/^[A-Za-z0-9_-]{40,60}$/.test(token)) return res.status(404).json({error: 'Shared record not found or expired'});
    const tokenHash = createHash('sha256').update(token).digest('hex');
    const share = await ExternalShare.findOne({tokenHash, revokedAt: {$exists: false}, expiresAt: {$gt: new Date()}}).select('+tokenHash');
    if (!share) return res.status(404).json({error: 'Shared record not found or expired'});
    await ExternalShare.updateOne({_id: share._id}, {$inc: {accessCount: 1}, $set: {lastAccessAt: new Date()}});
    if (share.entityType === 'document') {
      const document = BusinessDocument ? await BusinessDocument.findOne({_id: share.entityId, organizationId: share.organizationId}).lean() : null;
      if (!document) return res.status(404).json({error: 'Shared record not found or expired'});
      return res.json({share: {
        type: 'document', number: document.number, documentType: document.type, status: document.status,
        currency: document.currency, items: (document.items || []).map(item => ({name: item.name, quantity: item.quantity, unitPrice: item.unitPrice, lineTotal: item.lineTotal})),
        subtotal: document.subtotal, tax: document.tax, total: document.total, paidAmount: document.paidAmount,
        outstandingAmount: Math.max(0, Number(document.total || 0) - Number(document.paidAmount || 0)),
        dueDate: document.dueDate || null, issuedAt: document.createdAt || null, expiresAt: share.expiresAt,
      }});
    }
    const record = await EnterpriseRecord.findOne({_id: share.entityId, organizationId: share.organizationId}).lean();
    if (!record || !['project_room', 'customer_portal', 'service_policy', 'delivery_proof'].includes(record.type)) return res.status(404).json({error: 'Shared record not found or expired'});
    const updates = Array.isArray(record.payload?.customerUpdates) ? record.payload.customerUpdates.slice(-20).map(item => ({
      message: textValue(item?.message, 1000), status: textValue(item?.status, 80), occurredAt: item?.occurredAt || null,
    })) : [];
    return res.json({share: {
      type: record.type, title: record.title, status: record.status,
      description: textValue(record.payload?.publicDescription, 2000),
      dueAt: record.dueAt || null, updates, expiresAt: share.expiresAt,
    }});
  });

  app.post(base + '/shares', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager', 'sales', 'support', 'finance'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Business manager permission required'});
    const entityType = req.body?.entityType;
    const entityId = String(req.body?.entityId || '');
    if (!['document', 'enterprise_record'].includes(entityType) || !mongoose.isValidObjectId(entityId)) return res.status(400).json({error: 'Choose a valid document or customer-facing enterprise record'});
    if (entityType === 'document') {
      const document = BusinessDocument ? await BusinessDocument.findOne({_id: entityId, organizationId: org._id}) : null;
      if (!document || !['quote', 'order', 'invoice', 'receipt'].includes(document.type) || ['draft', 'rejected', 'cancelled'].includes(document.status)) return res.status(404).json({error: 'Shareable issued document not found'});
    } else {
      const record = await EnterpriseRecord.findOne({_id: entityId, organizationId: org._id});
      if (!record || !['project_room', 'customer_portal', 'service_policy', 'delivery_proof'].includes(record.type)) return res.status(400).json({error: 'Only customer-facing project, policy, portal and delivery records can be shared'});
    }
    const requestedHours = Number(req.body?.expiresInHours ?? 72);
    if (!Number.isInteger(requestedHours) || requestedHours < 1 || requestedHours > 720) return res.status(400).json({error: 'Share expiry must be between 1 hour and 30 days'});
    const token = randomBytes(32).toString('base64url');
    const expiresAt = new Date(Date.now() + requestedHours * 60 * 60 * 1000);
    const share = await ExternalShare.create({
      organizationId: org._id, entityType, entityId, tokenHash: createHash('sha256').update(token).digest('hex'),
      createdBy: req.user._id, expiresAt,
    });
    await audit(org, req, 'external_share.created', share, 'Created expiring customer-facing share link');
    res.status(201).json({
      shareId: String(share._id), token, path: '/api/business/public-shares/' + token,
      expiresAt, notice: 'This token is shown once. Share only with the intended customer; the link expires automatically and can be revoked.',
    });
  });

  app.get(base + '/shares', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const shares = await ExternalShare.find({organizationId: org._id}).sort({createdAt: -1}).limit(100).select('-tokenHash').lean();
    res.json({shares: shares.map(item => ({...item, tokenHash: undefined, expired: item.expiresAt <= new Date(), revoked: Boolean(item.revokedAt)}))});
  });

  app.delete(base + '/shares/:shareId', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager', 'finance', 'support'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Business manager permission required'});
    if (!mongoose.isValidObjectId(req.params.shareId)) return res.status(404).json({error: 'Share link not found'});
    const share = await ExternalShare.findOne({organizationId: org._id, _id: req.params.shareId});
    if (!share) return res.status(404).json({error: 'Share link not found'});
    if (share.revokedAt) return res.status(409).json({error: 'Share link is already revoked'});
    share.revokedAt = new Date(); await share.save();
    await audit(org, req, 'external_share.revoked', share, 'Revoked customer-facing share link');
    res.json({revoked: true, shareId: String(share._id)});
  });

  app.get(base + '/overview', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const [records, customers, catalog, documents, tasks, cases] = await Promise.all([
      EnterpriseRecord.find({organizationId: org._id}).lean(),
      Customer?.countDocuments({organizationId: org._id}) ?? 0,
      CatalogItem?.countDocuments({organizationId: org._id, active: true}) ?? 0,
      BusinessDocument?.countDocuments({organizationId: org._id, status: {$in: ['sent', 'accepted', 'part_paid']}}) ?? 0,
      BusinessTask?.countDocuments({organizationId: org._id, status: {$in: ['open', 'in_progress', 'blocked']}}) ?? 0,
      BusinessCase?.countDocuments({organizationId: org._id, status: {$nin: ['resolved', 'closed']}}) ?? 0,
    ]);
    const counts = Object.fromEntries(RECORD_TYPES.map(type => [type, records.filter(item => item.type === type && !['closed', 'cancelled', 'resolved'].includes(item.status)).length]));
    const due = records.filter(item => item.dueAt && new Date(item.dueAt) < new Date() && !['closed', 'cancelled', 'resolved', 'approved', 'rejected'].includes(item.status));
    res.json({
      organization: {id: String(org._id), name: org.name, industry: org.industry, plan: org.plan, currency: org.currency},
      counts, business: {customers, activeCatalogItems: catalog, outstandingDocuments: documents, openTasks: tasks, openCases: cases},
      overdueEnterpriseRecords: due.length,
      needsAttention: records.filter(item => item.priority === 'urgent' && !['closed', 'cancelled', 'resolved', 'approved', 'rejected'].includes(item.status)).slice(0, 10),
      generatedAt: new Date().toISOString(),
    });
  });

  app.get(base + '/readiness', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const [memberCount, catalogCount, customerCount] = await Promise.all([
      Promise.resolve((org.members || []).length),
      CatalogItem ? CatalogItem.countDocuments({organizationId: org._id, active: true}) : 0,
      Customer ? Customer.countDocuments({organizationId: org._id}) : 0,
    ]);
    const checks = [
      {key: 'profile', label: 'Business profile', complete: Boolean(org.name && org.industry && org.country && org.currency)},
      {key: 'team', label: 'Team access', complete: memberCount > 0},
      {key: 'catalog', label: 'Products or services', complete: catalogCount > 0},
      {key: 'customers', label: 'Customer records', complete: customerCount > 0},
      {key: 'mpesa', label: 'M-Pesa recipient configured', complete: Boolean(org.settings?.mpesaRecipientPhone)},
      {key: 'support', label: 'Support contact', complete: Boolean(org.email || org.phone)},
    ];
    res.json({checks, complete: checks.filter(item => item.complete).length, total: checks.length, ready: checks.every(item => item.complete)});
  });

  app.get(base + '/settings', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    // Never return integration secrets; only non-sensitive feature preferences and readiness metadata.
    const settings = org.settings || {};
    res.json({
      industry: org.industry, plan: org.plan, currency: org.currency, timezone: org.timezone,
      featureEntitlements: settings.featureEntitlements || {},
      serviceTargets: settings.serviceTargets || {firstResponseMinutes: 15, escalationMinutes: 60},
      creditPolicy: settings.creditPolicy || {enabled: false, defaultTermsDays: 0, approvalRequiredAbove: 0},
      recoveryContact: settings.recoveryContact || '',
      configuredIntegrations: {
        mpesaRecipientPhone: Boolean(settings.mpesaRecipientPhone),
        stripe: Boolean(process.env.STRIPE_SECRET_KEY),
        paypal: Boolean(process.env.PAYPAL_CLIENT_ID && process.env.PAYPAL_CLIENT_SECRET),
        etims: Boolean(process.env.ETIMS_GATEWAY_URL && process.env.ETIMS_GATEWAY_TOKEN),
      },
    });
  });

  app.patch(base + '/settings', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Business manager permission required'});
    const input = req.body || {};
    const allowed = ['featureEntitlements', 'serviceTargets', 'creditPolicy', 'recoveryContact'];
    if (!Object.keys(input).length || Object.keys(input).some(key => !allowed.includes(key))) return res.status(400).json({error: 'Unsupported settings field'});
    const settings = {...(org.settings?.toObject?.() || org.settings || {})};
    if (input.featureEntitlements !== undefined) {
      if (!input.featureEntitlements || typeof input.featureEntitlements !== 'object' || Array.isArray(input.featureEntitlements) || Object.keys(input.featureEntitlements).length > 50 || Object.values(input.featureEntitlements).some(value => typeof value !== 'boolean')) return res.status(400).json({error: 'Feature entitlements must be a map of boolean values'});
      settings.featureEntitlements = input.featureEntitlements;
    }
    if (input.serviceTargets !== undefined) {
      const targets = input.serviceTargets;
      if (!targets || typeof targets !== 'object' || !Number.isInteger(Number(targets.firstResponseMinutes)) || Number(targets.firstResponseMinutes) < 1 || Number(targets.firstResponseMinutes) > 10080 || !Number.isInteger(Number(targets.escalationMinutes)) || Number(targets.escalationMinutes) < Number(targets.firstResponseMinutes) || Number(targets.escalationMinutes) > 43200) return res.status(400).json({error: 'Response targets must be valid positive minutes; escalation must be no earlier than first response'});
      settings.serviceTargets = {firstResponseMinutes: Number(targets.firstResponseMinutes), escalationMinutes: Number(targets.escalationMinutes)};
    }
    if (input.creditPolicy !== undefined) {
      const policy = input.creditPolicy;
      if (!policy || typeof policy !== 'object' || typeof policy.enabled !== 'boolean' || !Number.isInteger(Number(policy.defaultTermsDays)) || Number(policy.defaultTermsDays) < 0 || Number(policy.defaultTermsDays) > 365 || !Number.isFinite(Number(policy.approvalRequiredAbove)) || Number(policy.approvalRequiredAbove) < 0) return res.status(400).json({error: 'Invalid credit policy'});
      settings.creditPolicy = {enabled: policy.enabled, defaultTermsDays: Number(policy.defaultTermsDays), approvalRequiredAbove: Number(policy.approvalRequiredAbove)};
    }
    if (input.recoveryContact !== undefined) {
      const contact = textValue(input.recoveryContact, 200);
      if (contact && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contact) && !/^\+?[0-9 ()-]{7,25}$/.test(contact)) return res.status(400).json({error: 'Recovery contact must be an email address or phone number'});
      settings.recoveryContact = contact;
    }
    org.settings = settings;
    await org.save();
    res.json({saved: true, settings: {featureEntitlements: settings.featureEntitlements || {}, serviceTargets: settings.serviceTargets || {}, creditPolicy: settings.creditPolicy || {}, recoveryContact: settings.recoveryContact || ''}});
  });

  app.get(base + '/usage', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const [members, customers, catalogItems, documents, tasks, enterpriseRecords] = await Promise.all([
      Promise.resolve((org.members || []).length + 1),
      Customer ? Customer.countDocuments({organizationId: org._id}) : 0,
      CatalogItem ? CatalogItem.countDocuments({organizationId: org._id}) : 0,
      BusinessDocument ? BusinessDocument.countDocuments({organizationId: org._id}) : 0,
      BusinessTask ? BusinessTask.countDocuments({organizationId: org._id}) : 0,
      EnterpriseRecord.countDocuments({organizationId: org._id}),
    ]);
    const plan = BUSINESS_PLAN_LIMITS[org.plan] ? org.plan : 'free';
    const [branches, workflows] = await Promise.all([Promise.resolve((org.branches || []).length), mongoose.models.BusinessWorkflow?.countDocuments({organizationId: org._id}) ?? 0]);
    const usage = {members, customers, catalogItems, documents, enterpriseRecords, branches, workflows};
    res.json({plan, usage, limits: BUSINESS_PLAN_LIMITS[plan], remaining: Object.fromEntries(Object.keys(usage).map(key => [key, Math.max(0, BUSINESS_PLAN_LIMITS[plan][key] - usage[key])])), notice: 'Write APIs enforce these workspace quotas. Paid plan activation and recurring subscription billing still require a verified billing workflow.'});
  });


  app.get(base + '/financial-periods', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager', 'finance'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Finance or manager permission required'});
    const periods = await EnterpriseRecord.find({organizationId: org._id, type: 'financial_close'}).sort({'payload.periodStart': -1}).limit(100).lean();
    res.json({periods});
  });

  app.post(base + '/financial-periods/close', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager', 'finance'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Finance or manager permission required'});
    const start = validDate(req.body?.periodStart);
    const end = validDate(req.body?.periodEnd);
    if (!start || !end || start >= end) return res.status(400).json({error: 'Choose a valid period start and end; end must be after start'});
    const periodStart = start.toISOString();
    const periodEnd = end.toISOString();
    const existing = await EnterpriseRecord.findOne({organizationId: org._id, type: 'financial_close', 'payload.periodStart': periodStart, 'payload.periodEnd': periodEnd});
    if (existing) return res.status(409).json({error: 'This financial period is already closed', record: existing});
    // Include every invoice issued before the period end so the close snapshot can calculate
    // receipts received during the period and outstanding balances as of that cut-off.
    const invoices = BusinessDocument ? await BusinessDocument.find({
      organizationId: org._id, type: 'invoice', createdAt: {$lt: end},
    }).select('number status total paidAmount paymentRecords createdAt').lean() : [];
    const periodInvoices = invoices.filter(invoice => new Date(invoice.createdAt) >= start);
    const roundMoney = value => Math.round(value * 100) / 100;
    const paymentsBeforeEnd = invoice => (invoice.paymentRecords || []).filter(payment =>
      payment.verified === true && payment.recordedAt && new Date(payment.recordedAt) < end,
    ).reduce((sum, payment) => sum + Number(payment.amount || 0), 0);
    const receiptsDuringPeriod = invoices.reduce((sum, invoice) => sum + (invoice.paymentRecords || []).filter(payment =>
      payment.verified === true && payment.recordedAt && new Date(payment.recordedAt) >= start && new Date(payment.recordedAt) < end,
    ).reduce((subtotal, payment) => subtotal + Number(payment.amount || 0), 0), 0);
    const invoiceTotal = periodInvoices.reduce((sum, invoice) => sum + Number(invoice.total || 0), 0);
    const outstandingTotal = invoices.reduce((sum, invoice) => sum + Math.max(0, Number(invoice.total || 0) - paymentsBeforeEnd(invoice)), 0);
    const snapshot = {
      periodStart, periodEnd, invoiceCount: periodInvoices.length,
      invoicedTotal: roundMoney(invoiceTotal), confirmedPaidTotal: roundMoney(receiptsDuringPeriod),
      outstandingTotal: roundMoney(outstandingTotal),
      invoiceStatuses: Object.fromEntries([...new Set(periodInvoices.map(item => item.status))].map(status => [status, periodInvoices.filter(item => item.status === status).length])),
      closedAt: new Date().toISOString(), closedBy: String(req.user._id),
    };
    const record = await EnterpriseRecord.create({
      organizationId: org._id, type: 'financial_close',
      title: 'Financial close ' + periodStart.slice(0, 10) + ' to ' + periodEnd.slice(0, 10),
      description: 'Immutable point-in-time snapshot of invoices created in this period. Later corrections should be recorded as adjustments.',
      status: 'closed', priority: 'normal', payload: snapshot, createdBy: req.user._id, updatedBy: req.user._id,
    });
    await audit(org, req, 'financial_period.closed', record, 'Closed financial period ' + periodStart.slice(0, 10) + ' to ' + periodEnd.slice(0, 10));
    res.status(201).json({record, notice: 'Snapshot is immutable. This does not prevent later invoices or verified payments; record corrections as separate adjustments.'});
  });

  app.get(base + '/records', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const filter = {organizationId: org._id};
    if (req.query.type) {
      if (!RECORD_TYPES.includes(String(req.query.type))) return res.status(400).json({error: 'Unsupported record type'});
      filter.type = String(req.query.type);
    }
    if (req.query.status) {
      if (!STATUSES.includes(String(req.query.status))) return res.status(400).json({error: 'Unsupported status'});
      filter.status = String(req.query.status);
    }
    if (req.query.q) {
      const q = textValue(req.query.q, 100);
      if (q.length < 2) return res.status(400).json({error: 'Search requires at least two characters'});
      filter.$or = [{title: {$regex: escapeRegex(q), $options: 'i'}}, {description: {$regex: escapeRegex(q), $options: 'i'}}];
    }
    const limit = Math.min(100, Math.max(1, Number(req.query.limit) || 50));
    const records = await EnterpriseRecord.find(filter).sort({updatedAt: -1}).limit(limit).lean();
    res.json({records, count: records.length, limit});
  });

  app.post(base + '/records', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org || !canWrite(req, res)) return;
    let normalized;
    if (req.body?.type === 'financial_close') return res.status(409).json({error: 'Financial periods must be closed through the snapshot endpoint'});
    try { normalized = normalizeEnterpriseRecord(req.body || {}); }
    catch (error) { return res.status(400).json({error: error.message}); }
    // High-risk actions start pending and cannot self-approve through the create endpoint.
    if (['approval', 'refund_case', 'credit_profile', 'dispute', 'support_case', 'incident'].includes(normalized.type)) normalized.status = 'pending';
    const enterpriseUsage = await EnterpriseRecord.countDocuments({organizationId: org._id});
    const quota = planQuotaStatus(org.plan, 'enterpriseRecords', enterpriseUsage);
    if (!quota.allowed) return res.status(402).json({error: 'This workspace has reached its current plan limit.', code: 'PLAN_LIMIT_REACHED', resource: 'enterpriseRecords', plan: quota.plan, limit: quota.limit, usage: enterpriseUsage, upgradeRequired: true});
    const record = await EnterpriseRecord.create({...normalized, organizationId: org._id, createdBy: req.user._id, updatedBy: req.user._id});
    await audit(org, req, 'enterprise_record.created', record, 'Created ' + record.type + ': ' + record.title);
    res.status(201).json({record});
  });

  app.patch(base + '/records/:recordId', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org || !canWrite(req, res)) return;
    if (!mongoose.isValidObjectId(req.params.recordId)) return res.status(404).json({error: 'Business record not found'});
    const record = await EnterpriseRecord.findOne({_id: req.params.recordId, organizationId: org._id});
    if (!record) return res.status(404).json({error: 'Business record not found'});
    if (record.type === 'financial_close') return res.status(409).json({error: 'Closed financial snapshots are immutable; create an adjustment record instead'});
    const changes = req.body || {};
    const allowed = ['title', 'description', 'priority', 'dueAt', 'assignedTo', 'payload'];
    if (!Object.keys(changes).length || Object.keys(changes).some(key => !allowed.includes(key))) return res.status(400).json({error: 'Only title, description, priority, dueAt, assignedTo and payload may be edited'});
    if (changes.title !== undefined) {
      const title = textValue(changes.title, 200); if (!title) return res.status(400).json({error: 'Title is required'}); record.title = title;
    }
    if (changes.description !== undefined) record.description = textValue(changes.description, 6000);
    if (changes.priority !== undefined) {
      if (!PRIORITIES.includes(changes.priority)) return res.status(400).json({error: 'Invalid priority'}); record.priority = changes.priority;
    }
    if (changes.dueAt !== undefined) {
      const dueAt = validDate(changes.dueAt); if (dueAt === null) return res.status(400).json({error: 'Invalid due date'}); record.dueAt = dueAt;
    }
    if (changes.assignedTo !== undefined) {
      if (changes.assignedTo && !mongoose.isValidObjectId(changes.assignedTo)) return res.status(400).json({error: 'Invalid assignee'});
      record.assignedTo = changes.assignedTo || undefined;
    }
    if (changes.payload !== undefined) {
      if (!changes.payload || typeof changes.payload !== 'object' || Array.isArray(changes.payload)) return res.status(400).json({error: 'Payload must be an object'});
      record.payload = changes.payload;
    }
    record.updatedBy = req.user._id;
    await record.save(); await audit(org, req, 'enterprise_record.updated', record, 'Updated ' + record.type + ': ' + record.title);
    res.json({record});
  });

  app.post(base + '/records/:recordId/acknowledge', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!mongoose.isValidObjectId(req.params.recordId)) return res.status(404).json({error: 'Business record not found'});
    const record = await EnterpriseRecord.findOne({_id: req.params.recordId, organizationId: org._id});
    if (!record) return res.status(404).json({error: 'Business record not found'});
    if (record.type !== 'handbook' && record.type !== 'service_policy') return res.status(409).json({error: 'Only handbook and service policy records require acknowledgement'});
    if (!record.acknowledgements.some(item => String(item.userId) === String(req.user._id))) record.acknowledgements.push({userId: req.user._id, acknowledgedAt: new Date()});
    await record.save(); await audit(org, req, 'enterprise_record.acknowledged', record, 'Acknowledged ' + record.title);
    res.json({record});
  });

  app.post(base + '/records/:recordId/decision', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org || !canApprove(req, res)) return;
    const decision = req.body?.decision;
    if (!['approved', 'rejected'].includes(decision)) return res.status(400).json({error: 'Decision must be approved or rejected'});
    const reason = textValue(req.body?.reason, 1000);
    if (decision === 'rejected' && !reason) return res.status(400).json({error: 'A reason is required when rejecting a request'});
    if (!mongoose.isValidObjectId(req.params.recordId)) return res.status(404).json({error: 'Business record not found'});
    const record = await EnterpriseRecord.findOne({_id: req.params.recordId, organizationId: org._id});
    if (!record) return res.status(404).json({error: 'Business record not found'});
    if (!['approval', 'refund_case', 'credit_profile', 'dispute'].includes(record.type) || record.status !== 'pending') return res.status(409).json({error: 'This record is not awaiting approval'});
    if (String(record.createdBy) === String(req.user._id)) return res.status(403).json({error: 'The creator cannot approve their own request'});
    record.approvals.push({userId: req.user._id, decision, reason, decidedAt: new Date()});
    record.status = decision; record.updatedBy = req.user._id;
    await record.save(); await audit(org, req, 'enterprise_record.' + decision, record, decision + ' ' + record.title);
    res.json({record});
  });

  app.post(base + '/records/:recordId/resolve', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org || !canWrite(req, res)) return;
    if (!mongoose.isValidObjectId(req.params.recordId)) return res.status(404).json({error: 'Business record not found'});
    const record = await EnterpriseRecord.findOne({_id: req.params.recordId, organizationId: org._id});
    if (!record) return res.status(404).json({error: 'Business record not found'});
    if (['closed', 'cancelled', 'resolved'].includes(record.status)) return res.status(409).json({error: 'This record is already closed'});
    record.status = req.body?.status === 'closed' ? 'closed' : 'resolved';
    record.resolvedAt = new Date(); record.updatedBy = req.user._id;
    if (req.body?.resolution !== undefined) record.payload = {...(record.payload?.toObject?.() || record.payload || {}), resolution: textValue(req.body.resolution, 2000)};
    await record.save(); await audit(org, req, 'enterprise_record.resolved', record, 'Resolved ' + record.type + ': ' + record.title);
    res.json({record});
  });

  app.get(base + '/search', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    const q = textValue(req.query.q, 100);
    if (q.length < 2) return res.status(400).json({error: 'Search requires at least two characters'});
    const rx = new RegExp(escapeRegex(q), 'i');
    const limit = Math.min(25, Math.max(1, Number(req.query.limit) || 10));
    const [customers, catalog, documents, tasks, cases, enterprise] = await Promise.all([
      Customer ? Customer.find({organizationId: org._id, $or: [{name: rx}, {email: rx}, {phone: rx}, {company: rx}]}).limit(limit).lean() : [],
      CatalogItem ? CatalogItem.find({organizationId: org._id, $or: [{name: rx}, {sku: rx}, {description: rx}]}).limit(limit).lean() : [],
      BusinessDocument ? BusinessDocument.find({organizationId: org._id, $or: [{number: rx}, {notes: rx}]}).limit(limit).lean() : [],
      BusinessTask ? BusinessTask.find({organizationId: org._id, $or: [{title: rx}, {description: rx}]}).limit(limit).lean() : [],
      BusinessCase ? BusinessCase.find({organizationId: org._id, $or: [{title: rx}, {description: rx}]}).limit(limit).lean() : [],
      EnterpriseRecord.find({organizationId: org._id, $or: [{title: rx}, {description: rx}]}).limit(limit).lean(),
    ]);
    const results = [
      ...customers.map(item => ({type: 'customer', id: String(item._id), title: item.name, subtitle: item.company || item.email || item.phone || ''})),
      ...catalog.map(item => ({type: 'catalog', id: String(item._id), title: item.name, subtitle: item.sku || item.description || ''})),
      ...documents.map(item => ({type: 'document', id: String(item._id), title: item.number, subtitle: item.status + ' · ' + item.currency + ' ' + item.total})),
      ...tasks.map(item => ({type: 'task', id: String(item._id), title: item.title, subtitle: item.status || ''})),
      ...cases.map(item => ({type: 'case', id: String(item._id), title: item.title, subtitle: item.status || ''})),
      ...enterprise.map(item => ({type: item.type, id: String(item._id), title: item.title, subtitle: item.status || ''})),
    ];
    res.json({query: q, results: results.slice(0, 100)});
  });

  app.post(base + '/commitment-suggestions', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (typeof req.body?.text !== 'string' || req.body.text.length > 5000) return res.status(400).json({error: 'Provide conversation text up to 5000 characters'});
    res.json({suggestions: extractPromiseSuggestions(req.body.text), confirmed: false});
  });

  app.get(base + '/export', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org) return;
    if (!['owner', 'admin', 'manager', 'finance'].includes(req.businessEnterpriseRole)) return res.status(403).json({error: 'Finance or manager permission required'});
    const records = await EnterpriseRecord.find({organizationId: org._id}).sort({createdAt: 1}).lean();
    // CSV fields are escaped to prevent spreadsheet formula injection.
    const cell = value => {
      let result = String(value ?? '').replace(/[\r\n]+/g, ' ');
      if (/^[=+@\-]/.test(result)) result = "'" + result;
      return '"' + result.replace(/"/g, '""') + '"';
    };
    const lines = [['id', 'type', 'title', 'status', 'priority', 'createdAt', 'updatedAt', 'dueAt'].join(',')];
    for (const item of records) lines.push([item._id, item.type, item.title, item.status, item.priority, item.createdAt?.toISOString?.() || '', item.updatedAt?.toISOString?.() || '', item.dueAt?.toISOString?.() || ''].map(cell).join(','));
    res.set('Content-Type', 'text/csv; charset=utf-8');
    res.set('Content-Disposition', 'attachment; filename="chatify-business-records.csv"');
    res.send(lines.join('\r\n') + '\r\n');
  });

  // Platform-wide controls are restricted to explicitly configured user IDs; organization members
  // cannot access this console merely by being a business owner.
  app.get('/api/platform/admin/overview', auth, async (req, res) => {
    const allowed = new Set((process.env.CHATIFY_SUPER_ADMIN_USER_IDS || '').split(',').map(item => item.trim()).filter(Boolean));
    if (!allowed.has(String(req.user._id))) return res.status(404).json({error: 'Not found'});
    if (!Organization) return res.status(503).json({error: 'Business platform is not initialized'});
    const [businesses, enterpriseRecords] = await Promise.all([
      Organization.countDocuments({}),
      EnterpriseRecord.countDocuments({}),
    ]);
    res.json({
      businesses, enterpriseRecords,
      plans: await Organization.aggregate([{$group: {_id: '$plan', count: {$sum: 1}}}]),
      generatedAt: new Date().toISOString(),
      notice: 'Operational health and payment-provider status must be verified by configured infrastructure checks.',
    });
  });
}

function escapeRegex(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
