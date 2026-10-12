import {normalizeMpesaPhone, validPaymentAmount, newPaymentId} from './payments.js';
import {calculateInternationalTotals, extractBusinessMemoryCandidates, createMessagingProviders, createLanguageProvider, createEtimsProvider, createIdempotencyKey, detectOfflineConflict, newIntegrationRequestId} from './business-integrations.js';
// CHATIFY BUSINESS PLATFORM
// Business records live beside chat records, with organization-level authorization.
// This module deliberately keeps payment confirmation server-owned: a screenshot or
// client-submitted "paid" flag is never accepted as proof of payment.

const ROLES = Object.freeze(['owner', 'admin', 'manager', 'sales', 'finance', 'support', 'fulfilment', 'viewer']);
const TAX_MODES = Object.freeze(['exclusive','inclusive','none']);
const INDUSTRIES = Object.freeze(['retail', 'wholesale', 'consulting', 'tourism', 'hospitality', 'logistics', 'construction', 'salon', 'education', 'agriculture', 'real_estate', 'health_admin', 'legal', 'automotive', 'events', 'other']);
const DOCUMENT_TYPES = Object.freeze(['quote', 'order', 'invoice', 'receipt', 'purchase_order']);
const DOCUMENT_STATUSES = Object.freeze(['draft', 'sent', 'accepted', 'rejected', 'part_paid', 'paid', 'fulfilled', 'cancelled']);
const TASK_STATUSES = Object.freeze(['open', 'in_progress', 'blocked', 'done', 'cancelled']);
const CASE_STATUSES = Object.freeze(['open', 'waiting_customer', 'waiting_team', 'resolved', 'closed']);

export function slugifyBusinessName(value = '') {
  return String(value).normalize('NFKD').toLowerCase().replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);
}

export function calculateDocumentTotals(lines = [], taxRate = 0) {
  if (!Array.isArray(lines) || lines.length < 1 || lines.length > 100) throw new Error('A document must contain between 1 and 100 line items');
  if (!Number.isFinite(taxRate) || taxRate < 0 || taxRate > 100) throw new Error('Tax rate must be between 0 and 100 percent');
  const items = lines.map((line) => {
    const name = typeof line.name === 'string' ? line.name.trim().slice(0, 160) : '';
    const quantity = Number(line.quantity);
    const unitPrice = Number(line.unitPrice);
    if (!name || !Number.isFinite(quantity) || quantity <= 0 || quantity > 1000000 || !Number.isFinite(unitPrice) || unitPrice < 0 || unitPrice > 1000000000) throw new Error('Each line needs a name, positive quantity and non-negative unit price');
    const lineTotal = Math.round(quantity * unitPrice * 100) / 100;
    return {catalogItemId: line.catalogItemId || undefined, name, quantity, unitPrice: Math.round(unitPrice * 100) / 100, lineTotal};
  });
  const subtotal = Math.round(items.reduce((sum, line) => sum + line.lineTotal, 0) * 100) / 100;
  const tax = Math.round(subtotal * taxRate) / 100;
  return {items, subtotal, tax, taxRate, total: Math.round((subtotal + tax) * 100) / 100};
}

export function canTransitionBusinessDocument(from, to) {
  const transitions = {
    draft: ['sent', 'cancelled'], sent: ['accepted', 'rejected', 'cancelled'],
    accepted: ['part_paid', 'paid', 'fulfilled', 'cancelled'], part_paid: ['paid', 'cancelled'],
    paid: ['fulfilled'], rejected: [], fulfilled: [], cancelled: [],
  };
  return Boolean(transitions[from]?.includes(to));
}

export function buildBusinessBriefing({tasks = [], documents = [], cases = [], now = new Date()} = {}) {
  const overdue = tasks.filter(item => item.status !== 'done' && item.status !== 'cancelled' && item.dueAt && new Date(item.dueAt) < now);
  const dueSoon = tasks.filter(item => item.status !== 'done' && item.status !== 'cancelled' && item.dueAt && new Date(item.dueAt) >= now && new Date(item.dueAt) <= new Date(now.getTime() + 24 * 60 * 60 * 1000));
  const outstanding = documents.filter(item => ['sent', 'accepted', 'part_paid'].includes(item.status));
  const unresolved = cases.filter(item => !['resolved', 'closed'].includes(item.status));
  return {generatedAt: now.toISOString(), overdueTasks: overdue.length, tasksDueWithin24Hours: dueSoon.length, outstandingDocuments: outstanding.length, outstandingAmount: Math.round(outstanding.reduce((sum, item) => sum + Math.max(0, Number(item.total || 0) - Number(item.paidAmount || 0)), 0) * 100) / 100, unresolvedCases: unresolved.length, nextActions: [...overdue, ...dueSoon].slice(0, 10).map(item => ({id: String(item._id || item.id || ''), title: item.title, dueAt: item.dueAt, status: item.status}))};
}

export function registerBusinessRoutes({app, auth, mongoose, User, Conversation, Payment, io, mpesaProvider}) {
  const O = mongoose.Schema.Types.ObjectId;
  const messaging = createMessagingProviders(process.env);
  const language = createLanguageProvider(process.env);
  const etims = createEtimsProvider(process.env);
  const memberSchema = new mongoose.Schema({userId: {type: O, ref: 'User', required: true}, role: {type: String, enum: ROLES, default: 'viewer'}, branchIds: {type: [O], default: []}}, {_id: false});
  const Organization = mongoose.models.BusinessOrganization || mongoose.model('BusinessOrganization', new mongoose.Schema({
    name: {type: String, required: true, trim: true, maxlength: 120}, slug: {type: String, required: true, unique: true, lowercase: true},
    ownerId: {type: O, ref: 'User', required: true, index: true}, industry: {type: String, enum: INDUSTRIES, default: 'other'},
    description: {type: String, maxlength: 2000, default: ''}, email: String, phone: String, website: String,
    country: {type: String, default: 'KE'}, currency: {type: String, default: 'KES'}, timezone: {type: String, default: 'Africa/Nairobi'},
    plan: {type: String, enum: ['free', 'business_pro', 'teams', 'enterprise'], default: 'free'},
    members: {type: [memberSchema], default: []}, settings: {type: mongoose.Schema.Types.Mixed, default: {}},
    branches: {type: [{name: String, address: String, phone: String, active: {type: Boolean, default: true}}], default: []},
  }, {timestamps: true}));
  Organization.schema.index({'members.userId': 1});
  const Customer = mongoose.models.BusinessCustomer || mongoose.model('BusinessCustomer', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, name: {type: String, required: true, trim: true, maxlength: 160},
    email: String, phone: String, company: String, notes: {type: String, maxlength: 4000}, tags: {type: [String], default: []},
    source: {type: String, enum: ['manual', 'chat', 'storefront', 'referral', 'import', 'other'], default: 'manual'},
    messagingConsent: {type: Boolean, default: false}, consentCapturedAt: Date,
    conversationId: O, assignedTo: O, lastContactAt: Date, customFields: {type: mongoose.Schema.Types.Mixed, default: {}},
  }, {timestamps: true}));
  Customer.schema.index({organizationId: 1, name: 1});
  const CatalogItem = mongoose.models.BusinessCatalogItem || mongoose.model('BusinessCatalogItem', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, type: {type: String, enum: ['product', 'service'], default: 'product'},
    name: {type: String, required: true, trim: true, maxlength: 180}, sku: {type: String, trim: true, maxlength: 80},
    description: {type: String, maxlength: 4000, default: ''}, price: {type: Number, required: true, min: 0},
    currency: {type: String, default: 'KES'}, stock: {type: Number, min: 0, default: 0}, lowStockAt: {type: Number, min: 0, default: 5},
    images: {type: [String], default: []}, active: {type: Boolean, default: true}, supplierId: O, category: String,
  }, {timestamps: true}));
  CatalogItem.schema.index({organizationId: 1, sku: 1}, {unique: true, sparse: true});
  const BusinessDocument = mongoose.models.BusinessDocument || mongoose.model('BusinessDocument', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, customerId: {type: O, index: true}, conversationId: O,
    type: {type: String, enum: DOCUMENT_TYPES, required: true}, number: {type: String, required: true},
    status: {type: String, enum: DOCUMENT_STATUSES, default: 'draft', index: true},
    items: {type: [{catalogItemId: O, name: String, quantity: Number, unitPrice: Number, discount: Number, lineTotal: Number}], default: []},
    subtotal: {type: Number, default: 0}, taxRate: {type: Number, default: 0}, taxMode: {type: String, enum: TAX_MODES, default: 'exclusive'}, tax: {type: Number, default: 0},
    total: {type: Number, default: 0}, paidAmount: {type: Number, default: 0}, currency: {type: String, default: 'KES'},
    etimsStatus: {type: String, enum: ['not_submitted','pending_review','submitted_pending_verification','rejected'], default: 'not_submitted'}, etimsControlUnitInvoiceNumber: String, etimsSubmittedAt: Date, etimsProviderStatus: String, etimsIdempotencyKey: String,
    dueDate: Date, notes: {type: String, maxlength: 4000}, paymentRecords: {type: [{amount: Number, method: String, reference: String, verified: {type: Boolean, default: false}, recordedAt: Date, recordedBy: O}], default: []},
    acceptedAt: Date, fulfilledAt: Date, createdBy: O, branchId: O,
  }, {timestamps: true}));
  BusinessDocument.schema.index({organizationId: 1, number: 1}, {unique: true});
  const BusinessTask = mongoose.models.BusinessTask || mongoose.model('BusinessTask', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, title: {type: String, required: true, maxlength: 200},
    description: {type: String, maxlength: 4000, default: ''}, type: {type: String, enum: ['task', 'commitment', 'appointment', 'delivery', 'follow_up', 'maintenance'], default: 'task'},
    status: {type: String, enum: TASK_STATUSES, default: 'open', index: true}, priority: {type: String, enum: ['low', 'normal', 'high', 'urgent'], default: 'normal'},
    dueAt: Date, assignedTo: O, customerId: O, documentId: O, conversationId: O, branchId: O, location: String,
    confirmations: {type: [{userId: O, confirmedAt: Date, note: String}], default: []}, completedAt: Date, createdBy: O,
  }, {timestamps: true}));
  const BusinessCase = mongoose.models.BusinessCase || mongoose.model('BusinessCase', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, customerId: O, conversationId: O,
    title: {type: String, required: true, maxlength: 200}, description: {type: String, maxlength: 6000, default: ''},
    status: {type: String, enum: CASE_STATUSES, default: 'open', index: true}, priority: {type: String, enum: ['low', 'normal', 'high', 'urgent'], default: 'normal'},
    assignees: {type: [O], default: []}, updates: {type: [{authorId: O, body: String, createdAt: Date}], default: []}, dueAt: Date,
  }, {timestamps: true}));
  const Supplier = mongoose.models.BusinessSupplier || mongoose.model('BusinessSupplier', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, name: {type: String, required: true, maxlength: 160},
    email: String, phone: String, address: String, notes: String, reliabilityNotes: String, active: {type: Boolean, default: true},
  }, {timestamps: true}));
  const Workflow = mongoose.models.BusinessWorkflow || mongoose.model('BusinessWorkflow', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, name: {type: String, required: true, maxlength: 160},
    description: {type: String, maxlength: 1000}, trigger: {type: String, enum: ['order_created', 'payment_confirmed', 'task_overdue', 'new_enquiry', 'manual', 'schedule'], default: 'manual'},
    scheduleEveryMinutes: {type: Number, min: 5, max: 10080, default: 60}, lastScheduledAt: Date,
    enabled: {type: Boolean, default: false}, actions: {type: [{actionType: {type: String, enum: ['create_task', 'notify_team', 'customer_message', 'create_receipt'], required: true}, config: mongoose.Schema.Types.Mixed}], default: []},
    runs: {type: [{status: String, triggerData: mongoose.Schema.Types.Mixed, result: mongoose.Schema.Types.Mixed, ranAt: Date, ranBy: O}], default: []},
  }, {timestamps: true}));
  const SharedInboxAssignment = mongoose.models.BusinessInboxAssignment || mongoose.model('BusinessInboxAssignment', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, conversationId: {type: O, required: true}, assignedTo: O,
    status: {type: String, enum: ['open', 'waiting', 'resolved'], default: 'open'}, priority: {type: String, enum: ['normal', 'high', 'urgent'], default: 'normal'},
    handoverNote: {type: String, maxlength: 2000}, lastHandoverBy: O, lastHandoverAt: Date, customerId: O,
  }, {timestamps: true}));
  SharedInboxAssignment.schema.index({organizationId: 1, conversationId: 1}, {unique: true});
  // Audit events record who changed a business record without copying sensitive message/payment payloads.
  const BusinessAudit = mongoose.models.BusinessAudit || mongoose.model('BusinessAudit', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, actorId: {type: O, required: true},
    action: {type: String, required: true, maxlength: 100}, entityType: {type: String, maxlength: 80},
    entityId: String, summary: {type: String, maxlength: 300}, occurredAt: {type: Date, default: Date.now, index: true},
  }, {timestamps: false}));
  // Offline mutations are idempotent and retain a compact conflict result for safe retry.
  const BusinessSyncMutation = mongoose.models.BusinessSyncMutation || mongoose.model('BusinessSyncMutation', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, mutationId: {type: String, required: true}, actorId: {type: O, required: true},
    entityType: {type: String, enum: ['customer','catalog','task','case'], required: true}, entityId: {type: String, default: ''},
    status: {type: String, enum: ['applied','conflict','rejected'], required: true}, result: mongoose.Schema.Types.Mixed,
  }, {timestamps: true}));
  BusinessSyncMutation.schema.index({organizationId: 1, mutationId: 1}, {unique: true});
  const TradeRequest = mongoose.models.BusinessTradeRequest || mongoose.model('BusinessTradeRequest', new mongoose.Schema({
    organizationId: {type: O, required: true, index: true}, buyerId: O, supplierId: O, title: {type: String, required: true, maxlength: 200},
    quantity: {type: Number, min: 1}, budget: Number, currency: {type: String, default: 'KES'}, details: String,
    offers: {type: [{supplierId: O, amount: Number, leadTime: String, notes: String, createdAt: Date}], default: []},
    status: {type: String, enum: ['open', 'quoted', 'awarded', 'cancelled'], default: 'open'},
  }, {timestamps: true}));
  const getOrg = async (orgId, userId) => {
    if (!mongoose.isValidObjectId(orgId)) return null;
    return Organization.findOne({_id: orgId, $or: [{ownerId: userId}, {'members.userId': userId}]});
  };
  const requireOrg = async (req, res) => {
    const org = await getOrg(req.params.orgId, req.user._id);
    if (!org) { res.status(404).json({error: 'Business workspace not found'}); return null; }
    // Cache the authenticated member's role for subsequent route-level write checks.
    req.businessRole = String(org.ownerId) === String(req.user._id) ? 'owner' : (org.members.find(member => String(member.userId) === String(req.user._id))?.role || 'viewer');
    return org;
  };
  const canManage = (org, userId) => String(org.ownerId) === String(userId) || org.members.some(m => String(m.userId) === String(userId) && ['admin', 'manager'].includes(m.role));
  const requireManager = (org, req, res) => { if (!canManage(org, req.user._id)) { res.status(403).json({error: 'Business manager permission required'}); return false; } return true; };
  const requireContributor = (org, req, res) => { if (req.businessRole === 'viewer') { res.status(403).json({error: 'This business role is read-only'}); return false; } return true; };
  const requireFinance = (org, req, res) => { if (!['owner','admin','manager','finance'].includes(req.businessRole)) { res.status(403).json({error:'Finance or manager permission required'}); return false; } return true; };
  const safeError = (res, error) => {
    if (error?.code === 11000) return res.status(409).json({error: 'A record with that identifier already exists'});
    if (error?.name === 'ValidationError' || error instanceof TypeError || error instanceof RangeError) return res.status(400).json({error: error.message || 'Invalid business data'});
    console.error('Chatify business operation failed:', error?.message || 'unknown error');
    return res.status(500).json({error: 'Business operation failed'});
  };
  const recordAudit = async (org, userId, action, entityType, entityId, summary = '') => {
    try { await BusinessAudit.create({organizationId: org._id, actorId: userId, action, entityType, entityId: entityId ? String(entityId) : undefined, summary: shortText(summary, 300)}); }
    catch (error) { console.error('Chatify business audit write failed:', error?.message || 'unknown error'); }
  };
  const validId = id => mongoose.isValidObjectId(id);
  const shortText = (value, max = 200) => typeof value === 'string' ? value.trim().slice(0, max) : '';
  const listQuery = (Model, orgId, req) => {
    const filter = {organizationId: orgId};
    if (req.query.status) filter.status = String(req.query.status);
    if (req.query.customerId && validId(req.query.customerId)) filter.customerId = req.query.customerId;
    return Model.find(filter).sort({updatedAt: -1}).limit(Math.min(200, Math.max(1, Number(req.query.limit) || 50)));
  };

  // Create a business workspace. The creator becomes the owner and has full authority.
  app.post('/api/business/organizations', auth, async (req, res) => {
    try {
      const name = shortText(req.body?.name, 120); const slug = slugifyBusinessName(req.body?.slug || name);
      if (!name || !slug) return res.status(400).json({error: 'Business name is required'});
      const org = await Organization.create({name, slug, ownerId: req.user._id, industry: INDUSTRIES.includes(req.body?.industry) ? req.body.industry : 'other', description: shortText(req.body?.description, 2000), email: shortText(req.body?.email, 200), phone: shortText(req.body?.phone, 40), website: shortText(req.body?.website, 500), country: shortText(req.body?.country, 2) || 'KE', currency: shortText(req.body?.currency, 3) || 'KES', timezone: shortText(req.body?.timezone, 80) || 'Africa/Nairobi', members: [{userId: req.user._id, role: 'owner'}]});
      await recordAudit(org, req.user._id, 'organization.created', 'organization', org._id, 'Created business workspace'); res.status(201).json({organization: org});
    } catch (error) { safeError(res, error); }
  });
  app.get('/api/business/organizations', auth, async (req, res) => {
    const organizations = await Organization.find({$or: [{ownerId: req.user._id}, {'members.userId': req.user._id}]}).sort({updatedAt: -1}).limit(100);
    res.json({organizations});
  });
  app.get('/api/business/organizations/:orgId', auth, async (req, res) => {
    const org = await requireOrg(req, res); if (org) res.json({organization: org});
  });
  app.patch('/api/business/organizations/:orgId', auth, async (req, res) => {
    const org = await requireOrg(req, res); if (!org || !requireManager(org, req, res)) return;
    for (const key of ['name', 'description', 'email', 'phone', 'website', 'country', 'currency', 'timezone']) if (req.body?.[key] !== undefined) org[key] = shortText(req.body[key], key === 'description' ? 2000 : 500);
    if (req.body?.industry !== undefined && INDUSTRIES.includes(req.body.industry)) org.industry = req.body.industry;
    if (req.body?.plan && ['free', 'business_pro', 'teams', 'enterprise'].includes(req.body.plan)) org.plan = req.body.plan;
    if (req.body?.settings && typeof req.body.settings === 'object' && !Array.isArray(req.body.settings)) org.settings = {...org.settings, ...req.body.settings};
    await org.save(); res.json({organization: org});
  });
  app.post('/api/business/organizations/:orgId/members', auth, async (req, res) => {
    const org = await requireOrg(req, res); if (!org || !requireManager(org, req, res)) return;
    if (!validId(req.body?.userId) || !ROLES.includes(req.body?.role) || req.body.role === 'owner') return res.status(400).json({error: 'Choose a valid user and non-owner role'});
    const member = await User.findOne({_id: req.body.userId, status: 'active'}).select('_id name email');
    if (!member) return res.status(404).json({error: 'Active user not found'});
    const existing = org.members.find(item => String(item.userId) === String(member._id));
    if (existing) existing.role = req.body.role; else org.members.push({userId: member._id, role: req.body.role});
    await org.save(); res.status(201).json({members: org.members});
  });
  app.delete('/api/business/organizations/:orgId/members/:userId', auth, async (req, res) => {
    const org = await requireOrg(req, res); if (!org || !requireManager(org, req, res)) return;
    if (String(org.ownerId) === String(req.params.userId)) return res.status(400).json({error: 'The owner cannot be removed'});
    org.members = org.members.filter(item => String(item.userId) !== String(req.params.userId)); await org.save(); res.json({members: org.members});
  });

  // Customer relationship records are scoped to the organization, never to a caller-supplied owner ID.
  app.get('/api/business/organizations/:orgId/customers', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org) return; const q = shortText(req.query.q, 100).toLowerCase(); const candidates = await Customer.find({organizationId: org._id}).sort({updatedAt: -1}).limit(200); const customers = q ? candidates.filter(item => [item.name, item.email, item.phone, item.company].some(value => String(value || '').toLowerCase().includes(q))) : candidates; res.json({customers}); });
  app.post('/api/business/organizations/:orgId/customers', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return; const name = shortText(req.body?.name, 160); if (!name) return res.status(400).json({error: 'Customer name is required'}); try { const customer = await Customer.create({organizationId: org._id, name, email: shortText(req.body.email, 200), phone: shortText(req.body.phone, 40), company: shortText(req.body.company, 160), notes: shortText(req.body.notes, 4000), tags: Array.isArray(req.body.tags) ? req.body.tags.filter(x => typeof x === 'string').slice(0, 30).map(x => x.slice(0, 50)) : [], source: ['manual','chat','storefront','referral','import','other'].includes(req.body.source) ? req.body.source : 'manual', conversationId: validId(req.body.conversationId) ? req.body.conversationId : undefined, assignedTo: validId(req.body.assignedTo) ? req.body.assignedTo : req.user._id, lastContactAt: new Date()}); await recordAudit(org, req.user._id, 'customer.created', 'customer', customer._id, 'Added customer'); res.status(201).json({customer}); } catch (error) { safeError(res, error); } });
  app.patch('/api/business/organizations/:orgId/customers/:customerId', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return; if (!validId(req.params.customerId)) return res.status(400).json({error: 'Invalid customer ID'}); const customer = await Customer.findOne({_id: req.params.customerId, organizationId: org._id}); if (!customer) return res.status(404).json({error: 'Customer not found'}); for (const key of ['name','email','phone','company','notes','source','assignedTo','conversationId']) if (req.body?.[key] !== undefined && ['name','email','phone','company','notes'].includes(key)) customer[key] = shortText(req.body[key], key === 'notes' ? 4000 : 200); if (Array.isArray(req.body?.tags)) customer.tags = req.body.tags.filter(x => typeof x === 'string').slice(0,30).map(x=>x.slice(0,50)); await customer.save(); res.json({customer}); });
  app.delete('/api/business/organizations/:orgId/customers/:customerId', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireManager(org, req, res)) return; const result = await Customer.deleteOne({_id: req.params.customerId, organizationId: org._id}); if (!result.deletedCount) return res.status(404).json({error:'Customer not found'}); res.status(204).end(); });

  // Storefront catalogue doubles as the public product/service catalogue and an internal inventory view.
  app.get('/api/business/organizations/:orgId/catalog', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org) return; const items = await CatalogItem.find({organizationId: org._id, ...(req.query.all === 'true' ? {} : {active: true})}).sort({name: 1}).limit(500); res.json({items}); });
  app.post('/api/business/organizations/:orgId/catalog', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return; const name = shortText(req.body?.name, 180); const price = Number(req.body?.price); if (!name || !Number.isFinite(price) || price < 0) return res.status(400).json({error: 'A name and non-negative price are required'}); try { const item = await CatalogItem.create({organizationId: org._id, type: ['product','service'].includes(req.body.type) ? req.body.type : 'product', name, sku: shortText(req.body.sku,80), description: shortText(req.body.description,4000), price, currency: shortText(req.body.currency,3) || org.currency, stock: Math.max(0, Number(req.body.stock)||0), lowStockAt: Math.max(0, Number(req.body.lowStockAt)||5), images: Array.isArray(req.body.images) ? req.body.images.filter(x=>typeof x==='string'&&x.startsWith('https://')).slice(0,8) : [], category: shortText(req.body.category,80), active: req.body.active !== false}); await recordAudit(org, req.user._id, 'catalog.created', 'catalog_item', item._id, 'Added catalogue item'); res.status(201).json({item}); } catch (error) { safeError(res, error); } });
  app.patch('/api/business/organizations/:orgId/catalog/:itemId', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return; if (!validId(req.params.itemId)) return res.status(400).json({error:'Invalid catalogue item ID'}); const item = await CatalogItem.findOne({_id:req.params.itemId,organizationId:org._id}); if (!item) return res.status(404).json({error:'Catalogue item not found'}); for (const key of ['name','sku','description','category','currency']) if (req.body?.[key] !== undefined) item[key] = shortText(req.body[key], key==='description'?4000:180); if (req.body?.price !== undefined && Number.isFinite(Number(req.body.price)) && Number(req.body.price)>=0) item.price=Number(req.body.price); if (req.body?.stock !== undefined && Number.isFinite(Number(req.body.stock)) && Number(req.body.stock)>=0) item.stock=Number(req.body.stock); if (typeof req.body?.active === 'boolean') item.active=req.body.active; await item.save(); res.json({item}); });
  app.delete('/api/business/organizations/:orgId/catalog/:itemId', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return; const item = await CatalogItem.findOneAndUpdate({_id:req.params.itemId,organizationId:org._id},{active:false},{new:true}); if (!item) return res.status(404).json({error:'Catalogue item not found'}); res.json({item}); });

  // Quotes, orders, invoices and receipts share a consistent document model and immutable price snapshots.
  app.get('/api/business/organizations/:orgId/documents', auth, async (req, res) => { const org = await requireOrg(req, res); if (!org) return; res.json({documents: await listQuery(BusinessDocument, org._id, req)}); });
  app.post('/api/business/organizations/:orgId/documents', auth, async (req, res) => {
    const org = await requireOrg(req, res); if (!org || !requireContributor(org, req, res)) return;
    const type = req.body?.type; if (!DOCUMENT_TYPES.includes(type)) return res.status(400).json({error:'Document type must be quote, order, invoice, receipt or purchase_order'});
    if (req.body.customerId && !validId(req.body.customerId)) return res.status(400).json({error:'Invalid customer ID'});
    if (req.body.customerId && !await Customer.exists({_id:req.body.customerId,organizationId:org._id})) return res.status(404).json({error:'Customer not found in this business'});
    const taxProfile = org.settings?.taxProfile && typeof org.settings.taxProfile === 'object' ? org.settings.taxProfile : {currency:org.currency,mode:'exclusive',rate:0};
    let totals;
    try { totals = calculateInternationalTotals(req.body.items, {currency:taxProfile.currency || org.currency, mode:taxProfile.mode || 'exclusive', rate:Number(taxProfile.rate || 0)}); }
    catch (error) { return res.status(400).json({error:error.message}); }
    // If a line references a catalogue item, its name and price come from this organization's
    // active catalogue—not from a client-submitted amount. Ad-hoc lines remain supported.
    for (const line of totals.items) {
      if (!line.catalogItemId) continue;
      if (!validId(line.catalogItemId)) return res.status(400).json({error:'Invalid catalogue item ID'});
      const catalogItem = await CatalogItem.findOne({_id:line.catalogItemId, organizationId:org._id, active:true});
      if (!catalogItem) return res.status(404).json({error:'Referenced catalogue item is not active in this business'});
      line.name = catalogItem.name;
      line.unitPrice = catalogItem.price;
    }
    // Recalculate after catalogue prices are loaded so inclusive taxes and discounts remain correct.
    try { totals = calculateInternationalTotals(totals.items.map(line=>({name:line.name,quantity:line.quantity,unitPrice:line.unitPrice,discount:line.discount})), {currency:totals.currency,mode:totals.taxMode,rate:totals.taxRate}); }
    catch (error) { return res.status(400).json({error:error.message}); }
    const number = shortText(req.body.number,60) || `${type.toUpperCase().slice(0,3)}-${Date.now().toString(36).toUpperCase()}`;
    try { const document = await BusinessDocument.create({organizationId:org._id,customerId:req.body.customerId,conversationId:validId(req.body.conversationId)?req.body.conversationId:undefined,type,number,status:'draft',...totals,currency:totals.currency,taxMode:totals.taxMode,dueDate:req.body.dueDate?new Date(req.body.dueDate):undefined,notes:shortText(req.body.notes,4000),createdBy:req.user._id,branchId:validId(req.body.branchId)?req.body.branchId:undefined}); await recordAudit(org, req.user._id, 'document.created', 'document', document._id, 'Created ' + type); res.status(201).json({document}); } catch (error) { safeError(res,error); }
  });
  app.patch('/api/business/organizations/:orgId/documents/:documentId/status', auth, async (req, res) => {
    const org = await requireOrg(req,res); if (!org || !requireContributor(org, req, res)) return;
    const document = await BusinessDocument.findOne({_id:req.params.documentId,organizationId:org._id}); if (!document) return res.status(404).json({error:'Document not found'});
    const next = req.body?.status; if(next==='paid')return res.status(409).json({error:'Paid status can only be set by a provider-confirmed payment callback'}); if(document.type==='invoice'&&next==='fulfilled'&&document.paidAmount<document.total)return res.status(409).json({error:'An invoice must be fully paid before it can be fulfilled'}); if (!DOCUMENT_STATUSES.includes(next)||!canTransitionBusinessDocument(document.status,next)) return res.status(409).json({error:`Cannot change document from ${document.status} to ${String(next)}`});
    const previousStatus = document.status; document.status=next; if(next==='accepted')document.acceptedAt=new Date(); if(next==='fulfilled')document.fulfilledAt=new Date(); await document.save(); await recordAudit(org, req.user._id, 'document.status_changed', 'document', document._id, previousStatus + ' -> ' + next);
    // When a valid conversation was attached, share only the record status—not payment credentials.
    if (document.conversationId && io) io.to(String(document.conversationId)).emit('business:document-updated',{documentId:String(document._id),number:document.number,status:document.status,total:document.total});
    res.json({document});
  });
  app.post('/api/business/organizations/:orgId/documents/:documentId/payment-records', auth, async (req, res) => {
    const org = await requireOrg(req,res); if (!org || !requireContributor(org, req, res)) return;
    const document = await BusinessDocument.findOne({_id:req.params.documentId,organizationId:org._id}); if (!document) return res.status(404).json({error:'Document not found'});
    const amount=Number(req.body?.amount); const method=['mpesa','cash','bank','card','other'].includes(req.body?.method)?req.body.method:'other';
    const pendingUnverified = document.paymentRecords.filter(record => !record.verified).reduce((sum, record) => sum + Number(record.amount || 0), 0);
    if (!Number.isFinite(amount)||amount<=0||amount>document.total-document.paidAmount-pendingUnverified) return res.status(400).json({error:'Payment amount exceeds the remaining unrecorded balance'});
    // Manual entries remain unverified and do not reduce the confirmed paid balance.
    // This prevents a staff-entered cash/M-Pesa note from silently treating an invoice as paid.
    document.paymentRecords.push({amount,method,reference:shortText(req.body?.reference,160),verified:false,recordedAt:new Date(),recordedBy:req.user._id});
    await document.save(); res.status(201).json({document,notice:'Payment recorded as unverified. Reconcile with the provider before treating it as confirmed.'});
  });
  app.post('/api/business/organizations/:orgId/documents/:documentId/reconcile-chatify-payment', auth, async (req, res) => {
    const org = await requireOrg(req,res); if (!org || !requireContributor(org, req, res)) return;
    const document = await BusinessDocument.findOne({_id:req.params.documentId,organizationId:org._id}); if (!document) return res.status(404).json({error:'Document not found'});
    const payment = await Payment.findOne({paymentId:req.body?.paymentId,status:'SUCCESS'});
    if (!payment || !payment.checkoutRequestId || !payment.callbackProcessedAt || payment.businessDocumentId) return res.status(409).json({error:'No eligible unlinked provider-confirmed Chatify payment was found'});
    if (document.customerId && String(payment.payerId)!==String(document.customerId)) { /* Business customers are not Chatify accounts; the payment must be explicitly linked by the operator. */ }
    if (document.paymentRecords.some(p=>p.reference===payment.paymentId)) return res.status(409).json({error:'This payment has already been reconciled'});
    const amount=Number(payment.amount);
    const outstanding=Math.max(0,document.total-document.paidAmount);
    if (!outstanding) return res.status(409).json({error:'Document has no outstanding balance'});
    if (!Number.isFinite(amount)||amount<=0||amount>outstanding) return res.status(409).json({error:'Confirmed payment exceeds the document outstanding balance'});
    document.paymentRecords.push({amount,method:'mpesa',reference:payment.paymentId,verified:true,recordedAt:new Date(),recordedBy:req.user._id});
    document.paidAmount=Math.round((document.paidAmount+amount)*100)/100;
    if(document.paidAmount>=document.total)document.status='paid';else document.status='part_paid';
    await document.save(); res.json({document,verified:true});
  });

  // Task, appointment, commitment and delivery tracking share assignments, deadlines and confirmations.
  app.get('/api/business/organizations/:orgId/tasks', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({tasks:await listQuery(BusinessTask,org._id,req)});});
  app.post('/api/business/organizations/:orgId/tasks', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const title=shortText(req.body?.title,200);if(!title)return res.status(400).json({error:'Task title is required'});if(req.body.customerId&&!await Customer.exists({_id:req.body.customerId,organizationId:org._id}))return res.status(404).json({error:'Customer not found'});const task=await BusinessTask.create({organizationId:org._id,title,description:shortText(req.body.description,4000),type:['task','commitment','appointment','delivery','follow_up','maintenance'].includes(req.body.type)?req.body.type:'task',priority:['low','normal','high','urgent'].includes(req.body.priority)?req.body.priority:'normal',dueAt:req.body.dueAt?new Date(req.body.dueAt):undefined,assignedTo:validId(req.body.assignedTo)?req.body.assignedTo:req.user._id,customerId:validId(req.body.customerId)?req.body.customerId:undefined,documentId:validId(req.body.documentId)?req.body.documentId:undefined,conversationId:validId(req.body.conversationId)?req.body.conversationId:undefined,location:shortText(req.body.location,300),createdBy:req.user._id});await recordAudit(org, req.user._id, 'task.created', 'task', task._id, 'Created task / follow-up'); res.status(201).json({task});});
  app.patch('/api/business/organizations/:orgId/tasks/:taskId', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const task=await BusinessTask.findOne({_id:req.params.taskId,organizationId:org._id});if(!task)return res.status(404).json({error:'Task not found'});for(const key of ['title','description','location'])if(req.body?.[key]!==undefined)task[key]=shortText(req.body[key],key==='description'?4000:300);if(req.body?.status&&TASK_STATUSES.includes(req.body.status)){task.status=req.body.status;task.completedAt=req.body.status==='done'?new Date():undefined;}if(req.body?.priority&&['low','normal','high','urgent'].includes(req.body.priority))task.priority=req.body.priority;if(req.body?.dueAt!==undefined)task.dueAt=req.body.dueAt?new Date(req.body.dueAt):undefined;if(req.body?.assignedTo&&validId(req.body.assignedTo))task.assignedTo=req.body.assignedTo;await task.save();res.json({task});});
  app.post('/api/business/organizations/:orgId/tasks/:taskId/confirm', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const task=await BusinessTask.findOne({_id:req.params.taskId,organizationId:org._id});if(!task)return res.status(404).json({error:'Task not found'});task.confirmations.push({userId:req.user._id,confirmedAt:new Date(),note:shortText(req.body?.note,500)});await task.save();res.json({task});});

  // Shared inbox handover records preserve context when staff shifts change.
  app.get('/api/business/organizations/:orgId/inbox', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;const rows=await SharedInboxAssignment.find({organizationId:org._id}).sort({updatedAt:-1}).limit(200);res.json({assignments:rows});});
  app.put('/api/business/organizations/:orgId/inbox/:conversationId', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;if(!validId(req.params.conversationId)||!await Conversation.exists({_id:req.params.conversationId,participants:req.user._id}))return res.status(404).json({error:'Conversation not found or not accessible'});if(req.body?.assignedTo&&!org.members.some(m=>String(m.userId)===String(req.body.assignedTo))&&String(org.ownerId)!==String(req.body.assignedTo))return res.status(400).json({error:'Assignee must be a member of this business'});const assignment=await SharedInboxAssignment.findOneAndUpdate({organizationId:org._id,conversationId:req.params.conversationId},{$set:{assignedTo:validId(req.body?.assignedTo)?req.body.assignedTo:undefined,status:['open','waiting','resolved'].includes(req.body?.status)?req.body.status:'open',priority:['normal','high','urgent'].includes(req.body?.priority)?req.body.priority:'normal',...(req.body?.handoverNote!==undefined?{handoverNote:shortText(req.body.handoverNote,2000),lastHandoverBy:req.user._id,lastHandoverAt:new Date()}:{})}},{upsert:true,new:true,setDefaultsOnInsert:true});res.json({assignment});});

  // Support cases keep the conversation, responsible staff, status and escalation deadline together.
  app.get('/api/business/organizations/:orgId/cases', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({cases:await listQuery(BusinessCase,org._id,req)});});
  app.post('/api/business/organizations/:orgId/cases', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const title=shortText(req.body?.title,200);if(!title)return res.status(400).json({error:'Case title is required'});if(req.body.customerId&&!await Customer.exists({_id:req.body.customerId,organizationId:org._id}))return res.status(404).json({error:'Customer not found'});const item=await BusinessCase.create({organizationId:org._id,title,description:shortText(req.body.description,6000),customerId:validId(req.body.customerId)?req.body.customerId:undefined,conversationId:validId(req.body.conversationId)?req.body.conversationId:undefined,priority:['low','normal','high','urgent'].includes(req.body.priority)?req.body.priority:'normal',assignees:Array.isArray(req.body.assignees)?req.body.assignees.filter(validId).slice(0,30):[],dueAt:req.body.dueAt?new Date(req.body.dueAt):undefined});res.status(201).json({case:item});});
  app.post('/api/business/organizations/:orgId/cases/:caseId/updates', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const item=await BusinessCase.findOne({_id:req.params.caseId,organizationId:org._id});if(!item)return res.status(404).json({error:'Case not found'});const body=shortText(req.body?.body,3000);if(!body)return res.status(400).json({error:'Update message is required'});item.updates.push({authorId:req.user._id,body,createdAt:new Date()});if(req.body?.status&&CASE_STATUSES.includes(req.body.status))item.status=req.body.status;await item.save();res.json({case:item});});

  // Supplier and B2B trade records support quotation requests without pretending suppliers are verified.
  app.get('/api/business/organizations/:orgId/suppliers', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({suppliers:await Supplier.find({organizationId:org._id}).sort({name:1}).limit(300)});});
  app.post('/api/business/organizations/:orgId/suppliers', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const name=shortText(req.body?.name,160);if(!name)return res.status(400).json({error:'Supplier name is required'});const supplier=await Supplier.create({organizationId:org._id,name,email:shortText(req.body.email,200),phone:shortText(req.body.phone,40),address:shortText(req.body.address,500),notes:shortText(req.body.notes,2000)});res.status(201).json({supplier});});
  app.get('/api/business/organizations/:orgId/trade-requests', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({tradeRequests:await TradeRequest.find({organizationId:org._id}).sort({updatedAt:-1}).limit(200)});});
  app.post('/api/business/organizations/:orgId/trade-requests', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const title=shortText(req.body?.title,200);if(!title)return res.status(400).json({error:'Trade request title is required'});const item=await TradeRequest.create({organizationId:org._id,buyerId:req.user._id,title,quantity:Number(req.body.quantity)||undefined,budget:Number(req.body.budget)||undefined,currency:shortText(req.body.currency,3)||org.currency,details:shortText(req.body.details,4000)});res.status(201).json({tradeRequest:item});});
  app.post('/api/business/organizations/:orgId/trade-requests/:requestId/offers', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;const item=await TradeRequest.findOne({_id:req.params.requestId,organizationId:org._id,status:{$in:['open','quoted']}});if(!item)return res.status(404).json({error:'Open trade request not found'});const amount=Number(req.body?.amount);if(!Number.isFinite(amount)||amount<0)return res.status(400).json({error:'Offer amount must be non-negative'});item.offers.push({supplierId:validId(req.body.supplierId)?req.body.supplierId:undefined,amount,leadTime:shortText(req.body.leadTime,120),notes:shortText(req.body.notes,1000),createdAt:new Date()});item.status='quoted';await item.save();res.status(201).json({tradeRequest:item});});

  // Workflow definitions are reviewable and logged. Automatic execution is opt-in and actions
  // are intentionally not executed as arbitrary code; financial actions require separate confirmation.
  app.get('/api/business/organizations/:orgId/workflows', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({workflows:await Workflow.find({organizationId:org._id}).sort({updatedAt:-1}).limit(100)});});
  app.post('/api/business/organizations/:orgId/workflows', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const name=shortText(req.body?.name,160);const actions=Array.isArray(req.body?.actions)?req.body.actions.slice(0,10):[];if(!name||!actions.length||actions.some(a=>!['create_task','notify_team','customer_message','create_receipt'].includes(a.actionType)))return res.status(400).json({error:'Provide a workflow name and supported actions'});const workflow=await Workflow.create({organizationId:org._id,name,description:shortText(req.body.description,1000),trigger:['order_created','payment_confirmed','task_overdue','new_enquiry','manual','schedule'].includes(req.body.trigger)?req.body.trigger:'manual',scheduleEveryMinutes:Math.min(10080,Math.max(5,Number(req.body.scheduleEveryMinutes)||60)),enabled:false,actions:actions.map(a=>({actionType:a.actionType,config:typeof a.config==='object'&&a.config? a.config : {}}))});res.status(201).json({workflow,notice:'Created disabled for review. Enable only after testing permissions and outcomes.'});});
  app.patch('/api/business/organizations/:orgId/workflows/:workflowId', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const workflow=await Workflow.findOne({_id:req.params.workflowId,organizationId:org._id});if(!workflow)return res.status(404).json({error:'Workflow not found'});if(typeof req.body?.enabled==='boolean'){if(req.body.enabled&&!workflow.runs.some(run=>run.status==='test_only'))return res.status(409).json({error:'Run a test-only preview before enabling this workflow'});workflow.enabled=req.body.enabled;}if(req.body?.name)workflow.name=shortText(req.body.name,160);if(req.body?.scheduleEveryMinutes!==undefined){const interval=Number(req.body.scheduleEveryMinutes);if(!Number.isInteger(interval)||interval<5||interval>10080)return res.status(400).json({error:'Schedule interval must be between 5 minutes and 7 days'});workflow.scheduleEveryMinutes=interval;}await workflow.save();res.json({workflow});});
  app.post('/api/business/organizations/:orgId/workflows/:workflowId/test', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;const workflow=await Workflow.findOne({_id:req.params.workflowId,organizationId:org._id});if(!workflow)return res.status(404).json({error:'Workflow not found'});const run={status:'test_only',triggerData:req.body?.sample||{},result:{wouldRun:workflow.actions.map(a=>a.actionType),executed:false},ranAt:new Date(),ranBy:req.user._id};workflow.runs.push(run);if(workflow.runs.length>100)workflow.runs=workflow.runs.slice(-100);await workflow.save();res.json({workflowId:String(workflow._id),test:run,notice:'Test mode records the proposed actions but does not send messages or move money.'});});

  // Dashboard, search, portability and a public read-only storefront for a verified slug.
  app.get('/api/business/organizations/:orgId/dashboard', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;const [customers,products,documents,tasks,cases,lowStock]=await Promise.all([Customer.countDocuments({organizationId:org._id}),CatalogItem.countDocuments({organizationId:org._id,active:true}),BusinessDocument.find({organizationId:org._id}).limit(500),BusinessTask.find({organizationId:org._id}).limit(500),BusinessCase.find({organizationId:org._id}).limit(500),CatalogItem.find({organizationId:org._id,active:true,$expr:{$lte:['$stock','$lowStockAt']}}).limit(100)]);res.json({organization:{id:String(org._id),name:org.name,industry:org.industry,plan:org.plan},metrics:{customers,activeCatalogItems:products,documents:documents.length,openTasks:tasks.filter(t=>!['done','cancelled'].includes(t.status)).length,openCases:cases.filter(c=>!['resolved','closed'].includes(c.status)).length,lowStockItems:lowStock.map(item=>({id:String(item._id),name:item.name,stock:item.stock,lowStockAt:item.lowStockAt})),briefing:buildBusinessBriefing({tasks,documents,cases})}});});
  app.get('/api/business/organizations/:orgId/search', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;const term=shortText(req.query.q,100);if(term.length<2)return res.status(400).json({error:'Search for at least two characters'});const safe=term.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');const regex=new RegExp(safe,'i');const [customers,documents,tasks,cases]=await Promise.all([Customer.find({organizationId:org._id,$or:[{name:regex},{email:regex},{phone:regex},{company:regex}]}).limit(20),BusinessDocument.find({organizationId:org._id,$or:[{number:regex},{notes:regex}]}).limit(20),BusinessTask.find({organizationId:org._id,$or:[{title:regex},{description:regex}]}).limit(20),BusinessCase.find({organizationId:org._id,$or:[{title:regex},{description:regex}]}).limit(20)]);res.json({query:term,results:{customers,documents,tasks,cases}});});
  // Branches let one organization manage several shops, offices or depots under one workspace.
  app.post('/api/business/organizations/:orgId/branches', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const name=shortText(req.body?.name,120);if(!name)return res.status(400).json({error:'Branch name is required'});org.branches.push({name,address:shortText(req.body.address,400),phone:shortText(req.body.phone,40),active:true});await org.save();const branch=org.branches[org.branches.length-1];await recordAudit(org,req.user._id,'branch.created','branch',branch._id,'Added branch');res.status(201).json({branch,branches:org.branches});});
  app.patch('/api/business/organizations/:orgId/branches/:branchId', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const branch=org.branches.id(req.params.branchId);if(!branch)return res.status(404).json({error:'Branch not found'});for(const key of ['name','address','phone'])if(req.body?.[key]!==undefined)branch[key]=shortText(req.body[key],key==='address'?400:120);if(typeof req.body?.active==='boolean')branch.active=req.body.active;await org.save();await recordAudit(org,req.user._id,'branch.updated','branch',branch._id,'Updated branch');res.json({branch});});
  app.get('/api/business/organizations/:orgId/audit-logs', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const limit=Math.min(200,Math.max(1,Number(req.query.limit)||50));const logs=await BusinessAudit.find({organizationId:org._id}).sort({occurredAt:-1}).limit(limit).lean();res.json({logs});});
  app.get('/api/business/organizations/:orgId/export', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const [customers,catalog,documents,tasks,cases,suppliers,workflows]=await Promise.all([Customer.find({organizationId:org._id}).lean(),CatalogItem.find({organizationId:org._id}).lean(),BusinessDocument.find({organizationId:org._id}).lean(),BusinessTask.find({organizationId:org._id}).lean(),BusinessCase.find({organizationId:org._id}).lean(),Supplier.find({organizationId:org._id}).lean(),Workflow.find({organizationId:org._id}).lean()]);res.setHeader('Content-Disposition',`attachment; filename="chatify-business-${org.slug}-${new Date().toISOString().slice(0,10)}.json"`);res.json({schemaVersion:1,exportedAt:new Date().toISOString(),organization:org.toObject(),customers,catalog,documents,tasks,cases,suppliers,workflows});});
  app.get('/api/business/storefront/:slug', async (req,res)=>{const org=await Organization.findOne({slug:String(req.params.slug).toLowerCase()}).select('name slug description industry country currency phone website');if(!org)return res.status(404).json({error:'Storefront not found'});const items=await CatalogItem.find({organizationId:org._id,active:true}).select('type name description price currency images category').sort({name:1}).limit(200);res.json({business:org,items});});
  app.post('/api/business/storefront/:slug/enquiries', async (req,res)=>{const org=await Organization.findOne({slug:String(req.params.slug).toLowerCase()}).select('_id');if(!org)return res.status(404).json({error:'Storefront not found'});const name=shortText(req.body?.name,160);const message=shortText(req.body?.message,2000);if(!name||!message)return res.status(400).json({error:'Your name and enquiry are required'});const customer=await Customer.create({organizationId:org._id,name,email:shortText(req.body.email,200),phone:shortText(req.body.phone,40),notes:message,source:'storefront'});res.status(201).json({ok:true,enquiryId:String(customer._id),message:'Enquiry received. The business can now follow up.'});});
  // Organization tax profiles make jurisdiction settings explicit; rates are operator-configured
  // and should be reviewed against current local tax rules before production invoicing.
  app.patch('/api/business/organizations/:orgId/tax-profile', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org||!requireFinance(org,req,res))return;const country=shortText(req.body?.country,2).toUpperCase();const currency=shortText(req.body?.currency,3).toUpperCase();const mode=req.body?.mode;const rate=Number(req.body?.rate);if(!/^[A-Z]{2}$/.test(country)||!SUPPORTED_TAX_MODES.includes(mode)||!Number.isFinite(rate)||rate<0||rate>100)return res.status(400).json({error:'Provide ISO country code, valid tax mode and a tax rate from 0 to 100'});try{calculateInternationalTotals([{name:'validation',quantity:1,unitPrice:1}],{currency,mode,rate});}catch(error){return res.status(400).json({error:error.message});}org.settings={...(org.settings||{}),taxProfile:{country,currency,mode,rate,taxLabel:shortText(req.body.taxLabel,80),registrationNumber:shortText(req.body.registrationNumber,80),updatedAt:new Date()}};org.currency=currency;org.country=country;await org.save();await recordAudit(org,req.user._id,'tax_profile.updated','organization',org._id,'Updated tax profile');res.json({taxProfile:org.settings.taxProfile,notice:'Tax profile saved. Verify rates and filing requirements with the relevant tax authority.'});});
  app.get('/api/business/organizations/:orgId/tax-profile', auth, async (req,res)=>{const org=await requireOrg(req,res);if(!org)return;res.json({taxProfile:org.settings?.taxProfile||{country:org.country,currency:org.currency,mode:'exclusive',rate:0}});});

  // Invoice-linked STK Push uses the existing provider-confirmed payment lifecycle. Mock mode is
  // clearly marked and cannot be represented as a real Safaricom payment.
  app.post('/api/business/organizations/:orgId/documents/:documentId/mpesa-stk', auth, async (req,res)=>{
    const org=await requireOrg(req,res);if(!org||!requireFinance(org,req,res))return;
    if(!mpesaProvider)return res.status(503).json({error:'M-Pesa provider is unavailable'});
    const document=await BusinessDocument.findOne({_id:req.params.documentId,organizationId:org._id});
    if(!document)return res.status(404).json({error:'Invoice not found'});
    if(document.type!=='invoice'||['draft','rejected','cancelled','fulfilled'].includes(document.status))return res.status(409).json({error:'Only a sent or accepted invoice can request payment'});
    if(document.currency!=='KES')return res.status(400).json({error:'M-Pesa STK is currently supported for KES invoices only'});
    const outstanding=Math.round((document.total-document.paidAmount)*100)/100;
    if(!Number.isSafeInteger(outstanding)||!validPaymentAmount(outstanding))return res.status(400).json({error:'M-Pesa requires a whole KSh outstanding balance between 1 and 150000'});
    const phone=normalizeMpesaPhone(req.body?.phone);if(!phone)return res.status(400).json({error:'Enter a valid Kenyan customer M-Pesa phone number'});
    const pending=await Payment.findOne({businessDocumentId:document._id,status:'PENDING',initiatedAt:{$exists:true}});
    if(pending)return res.status(409).json({error:'An M-Pesa request is already pending for this invoice',paymentId:pending.paymentId});
    const payment=await Payment.create({paymentId:newPaymentId(),requesterId:req.user._id,payerId:req.user._id,businessOrganizationId:org._id,businessDocumentId:document._id,amount:outstanding,recipientPhone:normalizeMpesaPhone(org.phone)||phone,payerPhone:phone,phone,description:('Invoice '+document.number).slice(0,80),provider:mpesaProvider.name,requestedAt:new Date(),initiating:true});
    try{const refs=await mpesaProvider.initiate({paymentId:payment.paymentId,amount:payment.amount,phone,description:payment.description});payment.checkoutRequestId=refs.checkoutRequestId;payment.merchantRequestId=refs.merchantRequestId;payment.initiatedAt=new Date();payment.initiating=false;await payment.save();await recordAudit(org,req.user._id,'invoice.mpesa_stk_initiated','document',document._id,'Started payment request for '+document.number);res.status(201).json({payment,mock:Boolean(mpesaProvider.isMock),notice:mpesaProvider.isMock?'Simulation only; no real Safaricom prompt was sent.':'M-Pesa prompt requested. Invoice updates only after a verified provider callback.'});}
    catch(error){payment.status='FAILED';payment.initiating=false;payment.completedAt=new Date();payment.callbackProcessedAt=new Date();payment.resultDescription='Provider initiation failed';await payment.save();console.error('Invoice M-Pesa initiation failed',{stage:error?.stage||'unknown'});res.status(503).json({error:'M-Pesa request could not be initiated. Check provider configuration and retry.'});}
  });

  // Only the explicitly configured approved gateway is contacted for eTIMS submission. HTTP 200
  // alone is not proof of fiscal acceptance; responses remain pending verification until reconciled.
  app.post('/api/business/organizations/:orgId/documents/:documentId/etims-submit', auth, async (req,res)=>{
    const org=await requireOrg(req,res);if(!org||!requireFinance(org,req,res))return;
    const document=await BusinessDocument.findOne({_id:req.params.documentId,organizationId:org._id});
    if(!document)return res.status(404).json({error:'Invoice not found'});
    if(document.type!=='invoice'||['draft','rejected','cancelled'].includes(document.status))return res.status(409).json({error:'Only issued invoices can be submitted'});
    if(document.etimsStatus!=='not_submitted')return res.status(409).json({error:'This invoice already has an eTIMS submission attempt',status:document.etimsStatus});
    if(!etims.configured)return res.status(503).json({error:'eTIMS is not configured. Add the approved gateway URL, token and taxpayer PIN to the server environment.'});
    const customer=document.customerId?await Customer.findOne({_id:document.customerId,organizationId:org._id}).lean():null;
    const idempotencyKey='etims:'+String(org._id)+':'+String(document._id);
    document.etimsIdempotencyKey=idempotencyKey;document.etimsStatus='pending_review';document.etimsSubmittedAt=new Date();await document.save();
    try{const result=await etims.submitInvoice({number:document.number,idempotencyKey,issueDate:document.createdAt?.toISOString(),currency:document.currency,customer:customer?{name:customer.name,email:customer.email,phone:customer.phone}:null,items:document.items,subtotal:document.subtotal,taxRate:document.taxRate,tax:document.tax,total:document.total});document.etimsStatus=result.status==='submitted_pending_verification'?'submitted_pending_verification':'pending_review';document.etimsControlUnitInvoiceNumber=result.controlUnitInvoiceNumber;document.etimsProviderStatus=result.providerResponse?.status||'awaiting verification';await document.save();await recordAudit(org,req.user._id,'invoice.etims_submitted','document',document._id,'Submitted invoice through configured gateway');res.status(202).json({document,submission:result,notice:'Verify the returned invoice identifier and fiscal status with your authorized eTIMS provider.'});}
    catch(error){document.etimsStatus='rejected';document.etimsProviderStatus='request_failed';await document.save();console.error('eTIMS gateway request failed',{status:error?.status||'unknown'});res.status(502).json({error:'The configured eTIMS gateway failed. Verify the gateway and provider logs before retrying.'});}
  });

  // Consent-gated communications: recipients must be customers in this workspace with recorded
  // opt-in. Message text and provider credentials are never written to audit logs.
  app.patch('/api/business/organizations/:orgId/customers/:customerId/messaging-consent', auth, async(req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;if(typeof req.body?.consent!=='boolean')return res.status(400).json({error:'consent must be true or false'});const customer=await Customer.findOne({_id:req.params.customerId,organizationId:org._id});if(!customer)return res.status(404).json({error:'Customer not found'});customer.messagingConsent=req.body.consent;customer.consentCapturedAt=req.body.consent?new Date():undefined;await customer.save();await recordAudit(org,req.user._id,'customer.messaging_consent_changed','customer',customer._id,req.body.consent?'Customer opted in':'Customer opt-in withdrawn');res.json({customer:{id:String(customer._id),messagingConsent:customer.messagingConsent,consentCapturedAt:customer.consentCapturedAt}});});
  app.post('/api/business/organizations/:orgId/communications/send', auth, async(req,res)=>{const org=await requireOrg(req,res);if(!org||!requireManager(org,req,res))return;const customer=await Customer.findOne({_id:req.body?.customerId,organizationId:org._id});if(!customer)return res.status(404).json({error:'Customer not found'});if(!customer.messagingConsent)return res.status(403).json({error:'Record the customer opt-in before sending a business message'});const channel=req.body?.channel;const message=shortText(req.body?.message,1500);if(!message)return res.status(400).json({error:'Message is required'});try{let delivery;if(channel==='whatsapp')delivery=await messaging.sendWhatsApp({to:customer.phone,text:message});else if(channel==='sms')delivery=await messaging.sendSms({to:customer.phone,text:message});else return res.status(400).json({error:'Channel must be whatsapp or sms'});await recordAudit(org,req.user._id,'customer.message_sent','customer',customer._id,'Sent '+channel+' message via configured provider');res.status(202).json({delivery,notice:'Provider accepted the message request; delivery is not guaranteed until provider status confirms it.'});}catch(error){console.error('Business messaging failed',{channel:String(channel||''),status:error?.status||'unconfigured'});res.status(503).json({error:'Messaging provider is unavailable or rejected the request. Check provider configuration.'});}});
  app.post('/api/business/organizations/:orgId/translate', auth, async(req,res)=>{const org=await requireOrg(req,res);if(!org)return;if(req.body?.consent!==true)return res.status(400).json({error:'Explicit consent is required before sending content to the configured translation provider'});try{const result=await language.translateText({text:req.body?.text,targetLanguage:req.body?.targetLanguage,sourceLanguage:req.body?.sourceLanguage});res.json(result);}catch(error){res.status(error.message?.includes('not configured')?503:400).json({error:error.message||'Translation failed'});}});
  app.post('/api/business/organizations/:orgId/voice-translate', auth, async(req,res)=>{const org=await requireOrg(req,res);if(!org)return;if(req.body?.consent!==true)return res.status(400).json({error:'Explicit consent is required before sending audio to the configured speech provider'});try{const result=await language.transcribeAndTranslate({audioBase64:req.body?.audioBase64,mimeType:req.body?.mimeType,targetLanguage:req.body?.targetLanguage});res.json(result);}catch(error){res.status(error.message?.includes('not configured')?503:400).json({error:error.message||'Voice translation failed'});}});
  app.post('/api/business/organizations/:orgId/memory-candidates', auth, async(req,res)=>{const org=await requireOrg(req,res);if(!org)return;const source=typeof req.body?.text==='string'?req.body.text:'';if(!source.trim()||source.length>5000)return res.status(400).json({error:'Provide business text up to 5000 characters'});res.json({candidates:extractBusinessMemoryCandidates(source),notice:'Suggestions only. Review before saving to Memory Cards or creating a task.'});});

  // Offline-first sync supports idempotent edits and returns a conflict instead of overwriting newer
  // server data. Clients can keep conflicts locally and ask the user which version to retain.
  app.post('/api/business/organizations/:orgId/sync', auth, async(req,res)=>{
    const org=await requireOrg(req,res);if(!org||!requireContributor(org,req,res))return;
    const mutations=Array.isArray(req.body?.mutations)?req.body.mutations:[];
    if(!mutations.length||mutations.length>50)return res.status(400).json({error:'Submit between 1 and 50 offline mutations'});
    const results=[];
    for(const mutation of mutations){
      let mutationId;try{mutationId=createIdempotencyKey(mutation?.mutationId);}catch(error){results.push({mutationId:null,status:'rejected',error:error.message});continue;}
      const prior=await BusinessSyncMutation.findOne({organizationId:org._id,mutationId});if(prior){results.push({mutationId,status:prior.status,...(prior.result||{})});continue;}
      const entityType=mutation?.entityType;const id=String(mutation?.entityId||'');const baseUpdatedAt=mutation?.baseUpdatedAt;const operation=mutation?.operation||'update';
      const Model=entityType==='customer'?Customer:entityType==='catalog'?CatalogItem:entityType==='task'?BusinessTask:entityType==='case'?BusinessCase:null;
      if(!Model||!mutation?.changes||typeof mutation.changes!=='object'||Array.isArray(mutation.changes)){results.push({mutationId,status:'rejected',error:'Unsupported entity or malformed mutation'});continue;}
      if(operation==='create'){
        const fields=mutation.changes;const allowed=entityType==='customer'?['name','email','phone','company','notes','tags']:entityType==='catalog'?['name','sku','description','price','stock','category','type','currency']:entityType==='task'?['title','description','status','priority','dueAt','type']:['title','description','priority','dueAt'];
        if(Object.keys(fields).some(key=>!allowed.includes(key))){results.push({mutationId,status:'rejected',error:'Create mutation contains unsupported fields'});continue;}
        const nameOrTitle=String(fields.name||fields.title||'').trim();
        if(!nameOrTitle){results.push({mutationId,status:'rejected',error:'Create mutation requires a name or title'});continue;}
        if(entityType==='catalog'&&(!Number.isFinite(Number(fields.price))||Number(fields.price)<0)){results.push({mutationId,status:'rejected',error:'A catalogue item requires a valid non-negative price'});continue;}
        if(fields.email&& !/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(String(fields.email))){results.push({mutationId,status:'rejected',error:'Invalid customer email'});continue;}
        const payload={organizationId:org._id,...fields};
        if(entityType==='customer'){payload.name=nameOrTitle;payload.source='manual';payload.messagingConsent=false;}
        if(entityType==='catalog'){payload.name=nameOrTitle;payload.price=Number(fields.price);payload.stock=Math.max(0,Number(fields.stock)||0);payload.currency=shortText(fields.currency,3)||org.currency;payload.active=true;}
        if(entityType==='task'){payload.title=nameOrTitle;payload.createdBy=req.user._id;payload.status=TASK_STATUSES.includes(fields.status)?fields.status:'open';payload.priority=['low','normal','high','urgent'].includes(fields.priority)?fields.priority:'normal';}
        if(entityType==='case'){payload.title=nameOrTitle;payload.priority=['low','normal','high','urgent'].includes(fields.priority)?fields.priority:'normal';}
        try{const created=await Model.create(payload);const result={record:created.toObject()};await BusinessSyncMutation.create({organizationId:org._id,mutationId,actorId:req.user._id,entityType,entityId:String(created._id),status:'applied',result});results.push({mutationId,status:'applied',...result});await recordAudit(org,req.user._id,'offline_sync.created',entityType,created._id,'Created record from offline queue');}catch(error){if(error.code===11000){const priorResult=await BusinessSyncMutation.findOne({organizationId:org._id,mutationId});results.push({mutationId,status:priorResult?.status||'rejected',...(priorResult?.result||{}),error:priorResult?undefined:'Record conflicts with an existing unique value'});}else{results.push({mutationId,status:'rejected',error:'Offline create could not be validated'});} }
        continue;
      }
      if(operation!=='update'||!validId(id)){results.push({mutationId,status:'rejected',error:'Update mutation requires a valid entity ID'});continue;}
      const record=await Model.findOne({_id:id,organizationId:org._id});if(!record){results.push({mutationId,status:'rejected',error:'Record not found in this business'});continue;}
      const conflict=detectOfflineConflict(record.updatedAt,baseUpdatedAt);
      if(conflict.conflict){const result={reason:conflict.reason,current:record.toObject()};await BusinessSyncMutation.create({organizationId:org._id,mutationId,actorId:req.user._id,entityType,entityId:id,status:'conflict',result});results.push({mutationId,status:'conflict',...result});continue;}
      const allowed=entityType==='customer'?['name','email','phone','company','notes','tags']:entityType==='catalog'?['name','sku','description','price','stock','active']:entityType==='task'?['title','description','status','priority','dueAt']:['title','description','status','priority','dueAt'];
      const changes=mutation.changes;const keys=Object.keys(changes);
      if(!keys.length||keys.some(key=>!allowed.includes(key))){results.push({mutationId,status:'rejected',error:'Mutation contains unsupported fields'});continue;}
      let invalid=null;
      for(const [key,value] of Object.entries(changes)){
        if(['price','stock'].includes(key)&&(!Number.isFinite(Number(value))||Number(value)<0))invalid='Price and stock must be non-negative numbers';
        else if(key==='active'&&typeof value!=='boolean')invalid='active must be boolean';
        else if(key==='status'&&entityType==='task'&&!TASK_STATUSES.includes(value))invalid='Invalid task status';
        else if(key==='priority'&&['task','case'].includes(entityType)&&!['low','normal','high','urgent'].includes(value))invalid='Invalid priority';
        else if(key==='dueAt'&&value!=null&&Number.isNaN(new Date(value).getTime()))invalid='Invalid due date';
        else if(key==='tags'&&(!Array.isArray(value)||value.length>30||value.some(v=>typeof v!=='string')))invalid='Tags must be a list of up to 30 strings';
        else if(!['price','stock','active','status','priority','dueAt','tags'].includes(key)&&typeof value!=='string')invalid='Invalid field value';
      }
      if(invalid){results.push({mutationId,status:'rejected',error:invalid});continue;}
      for(const [key,value] of Object.entries(changes)){
        if(['price','stock'].includes(key))record[key]=Number(value);
        else if(key==='dueAt')record[key]=value==null?null:new Date(value);
        else if(key==='tags')record[key]=value.map(v=>v.trim().slice(0,40));
        else if(typeof value==='string')record[key]=value.trim().slice(0,key==='notes'||key==='description'?4000:500);
        else record[key]=value;
      }
      await record.save();const result={record:record.toObject()};await BusinessSyncMutation.create({organizationId:org._id,mutationId,actorId:req.user._id,entityType,entityId:id,status:'applied',result});results.push({mutationId,status:'applied',...result});await recordAudit(org,req.user._id,'offline_sync.applied',entityType,id,'Applied offline change');
    }
    res.json({results,applied:results.filter(item=>item.status==='applied').length,conflicts:results.filter(item=>item.status==='conflict').length,rejected:results.filter(item=>item.status==='rejected').length});
  });

  // Scheduled workflows use a database compare-and-set so multiple app instances do not normally
  // run the same interval twice. Actions are intentionally allow-listed and audited.
  const runWorkflowTick = async () => {
    const now=new Date();
    const due=await Workflow.find({enabled:true,trigger:'schedule'}).limit(100);
    for(const candidate of due){
      const interval=Math.min(10080,Math.max(5,Number(candidate.scheduleEveryMinutes)||60));
      const cutoff=new Date(now.getTime()-interval*60000);
      const workflow=await Workflow.findOneAndUpdate({_id:candidate._id,enabled:true,trigger:'schedule',$or:[{lastScheduledAt:{$exists:false}},{lastScheduledAt:{$lte:cutoff}}]},{$set:{lastScheduledAt:now}},{new:true});
      if(!workflow)continue;
      const results=[];
      try{
        const organization=await Organization.findById(workflow.organizationId);if(!organization)continue;
        for(const action of workflow.actions){
          const config=action.config||{};
          if(action.actionType==='create_task'){
            const title=shortText(config.title,200)||workflow.name+' follow-up';
            const task=await BusinessTask.create({organizationId:organization._id,title,description:shortText(config.description,4000),type:'task',priority:['low','normal','high','urgent'].includes(config.priority)?config.priority:'normal',dueAt:config.dueInMinutes?new Date(now.getTime()+Math.min(525600,Math.max(1,Number(config.dueInMinutes)))*60000):undefined,createdBy:workflow.ownerId||organization.ownerId});
            results.push({actionType:action.actionType,status:'completed',taskId:String(task._id)});
          }else if(action.actionType==='notify_team'){
            const event={organizationId:String(organization._id),workflowId:String(workflow._id),title:workflow.name,message:shortText(config.message,300)||'A scheduled business workflow ran',occurredAt:now};
            io?.to('user:'+String(organization.ownerId)).emit('business:workflow-notification',event);
            for(const member of organization.members||[])io?.to('user:'+String(member.userId)).emit('business:workflow-notification',event);
            results.push({actionType:action.actionType,status:'completed'});
          }else if(action.actionType==='customer_message'){
            const customer=await Customer.findOne({_id:config.customerId,organizationId:organization._id,messagingConsent:true});
            if(!customer){results.push({actionType:action.actionType,status:'skipped',reason:'customer_consent_or_record_missing'});continue;}
            const message=shortText(config.message,1500);
            if(config.channel==='whatsapp')await messaging.sendWhatsApp({to:customer.phone,text:message});
            else if(config.channel==='sms')await messaging.sendSms({to:customer.phone,text:message});
            else {results.push({actionType:action.actionType,status:'skipped',reason:'unsupported_channel'});continue;}
            results.push({actionType:action.actionType,status:'submitted'});
          }else if(action.actionType==='create_receipt'){
            const document=await BusinessDocument.findOne({_id:config.documentId,organizationId:organization._id,type:'invoice',status:'paid'});
            if(!document){results.push({actionType:action.actionType,status:'skipped',reason:'paid_invoice_not_found'});continue;}
            const note='Automated receipt for '+document.number;
            if(await BusinessDocument.exists({organizationId:organization._id,type:'receipt',notes:note})){results.push({actionType:action.actionType,status:'skipped',reason:'receipt_already_exists'});continue;}
            const receipt=await BusinessDocument.create({organizationId:organization._id,type:'receipt',number:'REC-'+newIntegrationRequestId().slice(0,10).toUpperCase(),status:'paid',items:document.items,subtotal:document.paidAmount,taxRate:0,taxMode:'none',tax:0,total:document.paidAmount,paidAmount:document.paidAmount,currency:document.currency,notes:note,createdBy:organization.ownerId});
            results.push({actionType:action.actionType,status:'completed',receiptId:String(receipt._id)});
          }
        }
        workflow.runs.push({status:'completed',triggerData:{trigger:'schedule',scheduledAt:now},result:{actions:results},ranAt:now});
        if(workflow.runs.length>100)workflow.runs=workflow.runs.slice(-100);
        await workflow.save();
      }catch(error){workflow.runs.push({status:'failed',triggerData:{trigger:'schedule',scheduledAt:now},result:{error:'Workflow action failed'},ranAt:now});if(workflow.runs.length>100)workflow.runs=workflow.runs.slice(-100);await workflow.save().catch(()=>{});console.error('Business workflow failed',{workflowId:String(workflow._id)});}
    }
  };
  const workflowTimer=setInterval(()=>runWorkflowTick().catch(()=>console.error('Business workflow scheduler tick failed')),60000);
  workflowTimer.unref();
  app.post('/api/internal/business/workflows/tick',async(req,res)=>{const secret=process.env.BUSINESS_WORKFLOW_CRON_SECRET?.trim();if(!secret||req.get('authorization')!=='Bearer '+secret)return res.status(404).json({error:'Not found'});try{await runWorkflowTick();res.json({ok:true});}catch(error){res.status(500).json({error:'Workflow scheduler tick failed'});}});

}
