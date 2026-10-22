import {rejectLockedWorkspace} from './workspace-billing-access.js';
// Permission-aware, tenant-scoped search across Chatify Business records.
// Only a workspace owner/member can search it, and responses intentionally expose
// a small safe summary rather than returning full customer, payment, or document objects.
export function normalizeBusinessSearchQuery(value) {
  if (typeof value !== 'string') return '';
  return value.trim().replace(/\s+/g, ' ').slice(0, 100);
}

export function escapeSearchRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function registerBusinessSearchRoutes({app, auth, mongoose}) {
  const Organization = mongoose.models.BusinessOrganization;
  const EnterpriseRecord = mongoose.models.BusinessEnterpriseRecord;
  const base = '/api/business/organizations/:orgId/search';

  app.get(base, auth, async (req, res) => {
    const query = normalizeBusinessSearchQuery(req.query.q);
    if (query.length < 2) return res.status(400).json({error: 'Search query must contain at least 2 characters'});
    if (!Organization || !mongoose.isValidObjectId(req.params.orgId)) {
      return res.status(404).json({error: 'Business workspace not found'});
    }

    const organization = await Organization.findOne({
      _id: req.params.orgId,
      $or: [{ownerId: req.user._id}, {'members.userId': req.user._id}],
    }).select('_id billing').lean();
    if (!organization) return res.status(404).json({error: 'Business workspace not found'});
    if (await rejectLockedWorkspace(mongoose, organization, res)) return;

    const regex = new RegExp(escapeSearchRegex(query), 'i');
    const models = [
      {model: mongoose.models.BusinessCustomer, type: 'customer', fields: ['name', 'email', 'phone', 'company'], label: ['name', 'company', 'email', 'phone']},
      {model: mongoose.models.BusinessCatalogItem, type: 'product', fields: ['name', 'sku', 'description', 'category'], label: ['name', 'sku', 'category']},
      {model: mongoose.models.BusinessDocument, type: 'document', fields: ['number', 'type', 'status', 'customerName', 'description'], label: ['number', 'type', 'status', 'customerName']},
      {model: mongoose.models.BusinessTask, type: 'task', fields: ['title', 'description', 'status'], label: ['title', 'status']},
      {model: mongoose.models.BusinessCase, type: 'case', fields: ['title', 'subject', 'description', 'status'], label: ['title', 'subject', 'status']},
      {model: EnterpriseRecord, type: 'business_record', fields: ['title', 'description', 'status', 'type'], label: ['title', 'status', 'type']},
    ];
    const groups = await Promise.all(models.filter(item => item.model).map(async item => {
      // Query only fields present in each schema to remain compatible with older records.
      const searchable = item.fields.filter(field => item.model.schema.path(field));
      if (!searchable.length || !item.model.schema.path('organizationId')) return [];
      const found = await item.model.find({
        organizationId: organization._id,
        $or: searchable.map(field => ({[field]: regex})),
      }).sort({updatedAt: -1, createdAt: -1}).limit(8).lean();
      return found.map(record => ({
        id: String(record._id),
        type: item.type,
        title: String(item.label.map(field => record[field]).find(value => value != null && String(value).trim()) || item.type).slice(0, 180),
        status: String(record.status || 'available').slice(0, 40),
        updatedAt: record.updatedAt || record.createdAt || null,
      }));
    }));
    const results = groups.flat().sort((a, b) => new Date(b.updatedAt || 0) - new Date(a.updatedAt || 0)).slice(0, 40);
    res.json({query, results, count: results.length, generatedAt: new Date().toISOString()});
  });
}
