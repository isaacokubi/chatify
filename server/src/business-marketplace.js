// Public multi-business discovery for Chatify's commercial marketplace.
// This module deliberately exposes only published catalogue data and public business profile fields.
// All search text is escaped before it is used in a MongoDB regular expression.
export function normalizeMarketplaceFilters(query = {}) {
  const text = (value, max = 100) => typeof value === 'string' ? value.trim().replace(/\s+/g, ' ').slice(0, max) : '';
  const page = Number.parseInt(query.page, 10);
  const pageSize = Number.parseInt(query.pageSize, 10);
  return {
    q: text(query.q, 100).replace(/^@/, ''),
    category: text(query.category, 80),
    country: text(query.country, 2).toUpperCase(),
    location: text(query.location, 100),
    page: Number.isSafeInteger(page) && page > 0 ? Math.min(page, 100000) : 1,
    pageSize: Number.isSafeInteger(pageSize) && pageSize > 0 ? Math.min(pageSize, 50) : 20,
  };
}

export function escapeMarketplaceRegex(value = '') {
  return String(value).replace(/[.*+?^$()|[\]\\]/g, '\\$&');
}

export function matchesMarketplaceLocation(organization, location = '') {
  if (!location) return true;
  const term = location.toLocaleLowerCase();
  return [organization.country, ...(organization.branches || []).flatMap(branch => [branch.name, branch.address])]
    .some(value => String(value || '').toLocaleLowerCase().includes(term));
}

export function registerBusinessMarketplaceRoutes({app, mongoose}) {
  const Organization = mongoose.models.BusinessOrganization;
  const CatalogItem = mongoose.models.BusinessCatalogItem;

  // GET /api/marketplace supports keyword, category, country, location and pagination filters.
  app.get('/api/marketplace', async (req, res) => {
    try {
      if (!Organization || !CatalogItem) return res.status(503).json({error: 'Marketplace is temporarily unavailable'});
      const filters = normalizeMarketplaceFilters(req.query);
      const itemFilter = {active: true};
      if (filters.category) itemFilter.category = new RegExp(escapeMarketplaceRegex(filters.category), 'i');
      if (filters.q) {
        const term = new RegExp(escapeMarketplaceRegex(filters.q), 'i');
        itemFilter.$or = [{name: term}, {description: term}, {category: term}, {sku: term}];
      }
      const matchingItems = await CatalogItem.find(itemFilter).select('organizationId').limit(2000).lean();
      const itemOrganizationIds = [...new Set(matchingItems.map(item => String(item.organizationId)))];
      const organizationFilter = {'settings.storefrontPublished': {$ne: false}};
      if (filters.country) organizationFilter.country = new RegExp('^' + escapeMarketplaceRegex(filters.country) + '$', 'i');
      if (filters.q) {
        const term = new RegExp(escapeMarketplaceRegex(filters.q), 'i');
        organizationFilter.$or = [{name: term}, {slug: term}, {description: term}, {industry: term}, {_id: {$in: itemOrganizationIds}}];
      } else if (filters.category) {
        organizationFilter._id = {$in: itemOrganizationIds};
      }
      const organizations = await Organization.find(organizationFilter)
        .select('name slug description logo industry country currency website phone branches')
        .sort({name: 1}).limit(1000).lean();
      // Count active catalogue entries in one aggregation instead of issuing one query per store.
      const counts = await CatalogItem.aggregate([
        {$match: {active: true, organizationId: {$in: organizations.map(org => org._id)}}},
        {$group: {_id: '$organizationId', itemCount: {$sum: 1}}},
      ]);
      const countById = new Map(counts.map(row => [String(row._id), row.itemCount]));
      const eligible = organizations.flatMap(organization => {
        if (!matchesMarketplaceLocation(organization, filters.location)) return [];
        const itemCount = countById.get(String(organization._id)) || 0;
        if (!itemCount) return [];
        return [{
          id: String(organization._id), name: organization.name, slug: organization.slug, handle: organization.slug, storefrontPath: '/store/' + organization.slug,
          description: organization.description || '', logo: organization.logo || null,
          industry: organization.industry || 'other', country: organization.country || 'KE',
          currency: organization.currency || 'KES', website: organization.website || '',
          phone: organization.phone || '', itemCount,
        }];
      });
      const total = eligible.length;
      const start = (filters.page - 1) * filters.pageSize;
      res.set('Cache-Control', 'public, max-age=30, stale-while-revalidate=60');
      return res.json({filters, businesses: eligible.slice(start, start + filters.pageSize), pagination: {
        page: filters.page, pageSize: filters.pageSize, total, totalPages: Math.ceil(total / filters.pageSize),
      }});
    } catch (error) {
      console.error('Public marketplace search failed:', error?.message || 'unknown error');
      return res.status(500).json({error: 'Unable to search the marketplace right now'});
    }
  });

  // GET /api/marketplace/products searches active products and services across all public storefronts.
  app.get('/api/marketplace/products', async (req, res) => {
    try {
      if (!Organization || !CatalogItem) return res.status(503).json({error: 'Marketplace is temporarily unavailable'});
      const filters = normalizeMarketplaceFilters(req.query);
      const itemFilter = {active: true};
      if (filters.category) itemFilter.category = new RegExp(escapeMarketplaceRegex(filters.category), 'i');
      if (filters.q) {
        const term = new RegExp(escapeMarketplaceRegex(filters.q), 'i');
        itemFilter.$or = [{name: term}, {description: term}, {category: term}, {sku: term}];
      }
      const items = await CatalogItem.find(itemFilter)
        .select('organizationId name description price currency images category type stock')
        .sort({updatedAt: -1, name: 1}).limit(2000).lean();
      const orgIds = [...new Set(items.map(item => String(item.organizationId)))];
      const organizations = await Organization.find({
        _id: {$in: orgIds},
        'settings.storefrontPublished': {$ne: false},
        ...(filters.country ? {country: new RegExp('^' + escapeMarketplaceRegex(filters.country) + '$', 'i')} : {}),
      }).select('name slug country currency branches').lean();
      const byId = new Map(organizations.map(org => [String(org._id), org]));
      const results = items.flatMap(item => {
        const organization = byId.get(String(item.organizationId));
        if (!organization || !matchesMarketplaceLocation(organization, filters.location)) return [];
        return [{
          id: String(item._id), name: item.name, description: item.description || '',
          price: item.price, currency: item.currency || organization.currency || 'KES',
          images: (item.images || []).slice(0, 8), category: item.category || '',
          type: item.type || 'product', inStock: Number(item.stock) > 0,
          business: {name: organization.name, slug: organization.slug, country: organization.country || 'KE'},
        }];
      });
      const total = results.length;
      const start = (filters.page - 1) * filters.pageSize;
      res.set('Cache-Control', 'public, max-age=30, stale-while-revalidate=60');
      return res.json({filters, products: results.slice(start, start + filters.pageSize), pagination: {
        page: filters.page, pageSize: filters.pageSize, total, totalPages: Math.ceil(total / filters.pageSize),
      }});
    } catch (error) {
      console.error('Public marketplace product search failed:', error?.message || 'unknown error');
      return res.status(500).json({error: 'Unable to search marketplace products right now'});
    }
  });
}
