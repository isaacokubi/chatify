// Customer financial statements are computed from organization-owned document snapshots.
// This module exposes no private statement data to the public storefront.
export function buildCustomerStatement(documents, {from = null, to = null, now = new Date()} = {}) {
  const start = from ? new Date(from) : null;
  const end = to ? new Date(to) : null;
  if (start && !Number.isFinite(start.getTime())) throw new Error('Invalid statement start date');
  if (end && !Number.isFinite(end.getTime())) throw new Error('Invalid statement end date');
  if (start && end && start > end) throw new Error('Statement start date must not be after end date');
  const rows = documents.filter(document => {
    const created = new Date(document.createdAt || now);
    return (!start || created >= start) && (!end || created <= end);
  }).map(document => {
    const total = Math.round(Math.max(0, Number(document.total) || 0) * 100) / 100;
    const paid = Math.round(Math.min(total, Math.max(0, Number(document.paidAmount) || 0)) * 100) / 100;
    return {
      id: String(document._id || document.id || ''),
      number: String(document.number || ''),
      type: String(document.type || ''),
      status: String(document.status || ''),
      currency: String(document.currency || 'KES').toUpperCase(),
      date: document.createdAt || null,
      dueDate: document.dueDate || null,
      total,
      paidAmount: paid,
      balanceDue: Math.round((total - paid) * 100) / 100,
    };
  }).sort((a, b) => new Date(a.date || 0) - new Date(b.date || 0));
  const totals = {};
  for (const row of rows) {
    totals[row.currency] ||= {billed: 0, paid: 0, balanceDue: 0};
    totals[row.currency].billed = Math.round((totals[row.currency].billed + row.total) * 100) / 100;
    totals[row.currency].paid = Math.round((totals[row.currency].paid + row.paidAmount) * 100) / 100;
    totals[row.currency].balanceDue = Math.round((totals[row.currency].balanceDue + row.balanceDue) * 100) / 100;
  }
  return {generatedAt: now.toISOString(), period: {from: start?.toISOString() || null, to: end?.toISOString() || null}, count: rows.length, totals, documents: rows};
}

export function registerBusinessStatementRoutes({app, auth, mongoose}) {
  const Organization = mongoose.models.BusinessOrganization;
  const Customer = mongoose.models.BusinessCustomer;
  const Document = mongoose.models.BusinessDocument;

  app.get('/api/business/organizations/:orgId/customers/:customerId/statement', auth, async (req, res) => {
    try {
      if (!Organization || !Customer || !Document || !mongoose.isValidObjectId(req.params.orgId) || !mongoose.isValidObjectId(req.params.customerId)) {
        return res.status(404).json({error: 'Customer statement not found'});
      }
      const org = await Organization.findOne({
        _id: req.params.orgId,
        $or: [{ownerId: req.user._id}, {'members.userId': req.user._id}],
      }).select('_id ownerId members').lean();
      if (!org) return res.status(404).json({error: 'Business workspace not found'});
      const role = String(org.ownerId) === String(req.user._id)
        ? 'owner'
        : (org.members || []).find(member => String(member.userId) === String(req.user._id))?.role || 'viewer';
      if (!['owner', 'admin', 'manager', 'finance'].includes(role)) {
        return res.status(403).json({error: 'Finance or manager permission required'});
      }
      const customer = await Customer.findOne({_id: req.params.customerId, organizationId: org._id})
        .select('_id name email phone company').lean();
      if (!customer) return res.status(404).json({error: 'Customer not found in this business'});
      const from = typeof req.query.from === 'string' ? req.query.from : null;
      const to = typeof req.query.to === 'string' ? req.query.to : null;
      const filter = {organizationId: org._id, customerId: customer._id, type: {$in: ['invoice', 'receipt', 'order']}};
      if (from || to) {
        filter.createdAt = {};
        if (from) filter.createdAt.$gte = new Date(from);
        if (to) filter.createdAt.$lte = new Date(to);
        if (Object.values(filter.createdAt).some(date => !Number.isFinite(date.getTime()))) {
          return res.status(400).json({error: 'Use valid ISO dates for statement from/to filters'});
        }
        if (from && to && filter.createdAt.$gte > filter.createdAt.$lte) {
          return res.status(400).json({error: 'Statement start date must not be after end date'});
        }
      }
      const documents = await Document.find(filter)
        .select('_id number type status currency total paidAmount dueDate createdAt')
        .sort({createdAt: 1}).limit(500).lean();
      const statement = buildCustomerStatement(documents, {from, to});
      return res.json({customer, statement, truncated: documents.length === 500});
    } catch (error) {
      console.error('Customer statement generation failed:', error?.message || 'unknown error');
      return res.status(500).json({error: 'Unable to generate this customer statement right now'});
    }
  });
}
