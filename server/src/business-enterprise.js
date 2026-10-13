// CHATIFY BUSINESS ENTERPRISE EXTENSIONS
// This module adds organization-scoped workflows on top of the existing Business models.
// It intentionally keeps financial outcomes provider-verified and uses one tenant boundary
// for every record, search result, approval, acknowledgement, and support incident.
const RECORD_TYPES = Object.freeze([
  'handbook', 'notification', 'approval', 'refund_case', 'credit_profile',
  'project_room', 'supplier_quote', 'service_policy', 'delivery_proof',
  'dispute', 'consent_record', 'support_case', 'incident', 'integration',
  'migration_job', 'recovery_plan', 'promise', 'response_target', 'subscription_note',
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

  const getOrg = async (req, res) => {
    if (!Organization || !mongoose.isValidObjectId(req.params.orgId)) {
      res.status(404).json({error: 'Business workspace not found'}); return null;
    }
    const org = await Organization.findOne({
      _id: req.params.orgId,
      $or: [{ownerId: req.user._id}, {'members.userId': req.user._id}],
    });
    if (!org) { res.status(404).json({error: 'Business workspace not found'}); return null; }
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
    const limits = {free: {members: 3, customers: 100, catalogItems: 100, documents: 250, enterpriseRecords: 100}, business_pro: {members: 10, customers: 2000, catalogItems: 1000, documents: 5000, enterpriseRecords: 2500}, teams: {members: 50, customers: 20000, catalogItems: 10000, documents: 50000, enterpriseRecords: 20000}, enterprise: {members: 1000, customers: 1000000, catalogItems: 1000000, documents: 1000000, enterpriseRecords: 1000000}};
    const plan = limits[org.plan] ? org.plan : 'free';
    const usage = {members, customers, catalogItems, documents, enterpriseRecords};
    res.json({plan, usage, limits: limits[plan], remaining: Object.fromEntries(Object.keys(usage).map(key => [key, Math.max(0, limits[plan][key] - usage[key])])), notice: 'Usage visibility is informational; write-path quota enforcement must be enabled before selling hard limits.'});
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
    try { normalized = normalizeEnterpriseRecord(req.body || {}); }
    catch (error) { return res.status(400).json({error: error.message}); }
    // High-risk actions start pending and cannot self-approve through the create endpoint.
    if (['approval', 'refund_case', 'credit_profile', 'dispute', 'support_case', 'incident'].includes(normalized.type)) normalized.status = 'pending';
    const record = await EnterpriseRecord.create({...normalized, organizationId: org._id, createdBy: req.user._id, updatedBy: req.user._id});
    await audit(org, req, 'enterprise_record.created', record, 'Created ' + record.type + ': ' + record.title);
    res.status(201).json({record});
  });

  app.patch(base + '/records/:recordId', auth, async (req, res) => {
    const org = await getOrg(req, res); if (!org || !canWrite(req, res)) return;
    if (!mongoose.isValidObjectId(req.params.recordId)) return res.status(404).json({error: 'Business record not found'});
    const record = await EnterpriseRecord.findOne({_id: req.params.recordId, organizationId: org._id});
    if (!record) return res.status(404).json({error: 'Business record not found'});
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
