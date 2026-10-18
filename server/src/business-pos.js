// Chatify in-person POS payment intents for shops, supermarkets, malls and hospitality.
import {randomUUID} from 'node:crypto';

export const POS_METHODS = Object.freeze(['mpesa_till', 'mpesa_paybill']);

export function normalizeMerchantPaymentProfile(input = {}) {
  const method = POS_METHODS.includes(input.method) ? input.method : null;
  const tillNumber = String(input.tillNumber || '').trim().replace(/\s+/g, '').slice(0, 32);
  const paybillNumber = String(input.paybillNumber || '').trim().replace(/\s+/g, '').slice(0, 32);
  const accountNumber = String(input.accountNumber || '').trim().slice(0, 80);
  if (!method) throw new Error('Choose M-Pesa Till or Paybill');
  if (method === 'mpesa_till' && !/^\d{5,10}$/.test(tillNumber)) throw new Error('Enter a valid 5–10 digit M-Pesa Till number');
  if (method === 'mpesa_paybill' && !/^\d{5,10}$/.test(paybillNumber)) throw new Error('Enter a valid 5–10 digit M-Pesa Paybill number');
  if (method === 'mpesa_paybill' && !accountNumber) throw new Error('Enter the Paybill account/reference number');
  return {method, tillNumber: method === 'mpesa_till' ? tillNumber : '', paybillNumber: method === 'mpesa_paybill' ? paybillNumber : '', accountNumber: method === 'mpesa_paybill' ? accountNumber : ''};
}

export function buildPosCharge({organization, amount, description, reference, profile}) {
  const total = Number(amount);
  if (!Number.isSafeInteger(total) || total < 1 || total > 150000) throw new Error('Amount must be a whole number between KSh 1 and KSh 150,000');
  const title = String(description || '').trim().replace(/\s+/g, ' ').slice(0, 120);
  if (!title) throw new Error('Enter a sale description');
  const paymentReference = String(reference || randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase()).trim().slice(0, 32);
  const destination = profile.method === 'mpesa_till'
    ? {method: 'mpesa_till', tillNumber: profile.tillNumber}
    : {method: 'mpesa_paybill', paybillNumber: profile.paybillNumber, accountNumber: profile.accountNumber};
  const paymentId = randomUUID();
  const qr = {version: 1, type: 'chatify_pos_payment', paymentId, merchantId: String(organization._id), merchantName: String(organization.name), reference: paymentReference, amount: total, description: title, currency: 'KES', ...destination};
  return {paymentId, organizationId: organization._id, reference: paymentReference, amount: total, currency: 'KES', description: title, method: profile.method, destination, qrPayload: JSON.stringify(qr), status: 'PENDING', confirmationSource: null};
}

export function canUsePosRole(role) {
  return ['owner', 'admin', 'manager', 'sales', 'finance'].includes(String(role));
}

export function registerBusinessPosRoutes({app, auth, mongoose}) {
  const O = mongoose.Schema.Types.ObjectId;
  const Organization = mongoose.models.BusinessOrganization;
  if (!Organization) throw new Error('BusinessOrganization model must be registered before POS routes');
  const Charge = mongoose.models.BusinessPosCharge || mongoose.model('BusinessPosCharge', new mongoose.Schema({
    paymentId: {type: String, required: true, unique: true, index: true},
    organizationId: {type: O, required: true, index: true},
    createdBy: {type: O, required: true},
    reference: {type: String, required: true},
    amount: {type: Number, required: true, min: 1, max: 150000},
    currency: {type: String, enum: ['KES'], default: 'KES'},
    description: {type: String, required: true, maxlength: 120},
    method: {type: String, enum: POS_METHODS, required: true},
    destination: {type: mongoose.Schema.Types.Mixed, required: true},
    qrPayload: {type: String, required: true},
    status: {type: String, enum: ['PENDING', 'SUCCESS', 'FAILED', 'CANCELLED'], default: 'PENDING', index: true},
    confirmationSource: {type: String, default: null},
    providerReceipt: {type: String, default: null},
    confirmedAt: Date,
  }, {timestamps: true}));
  Charge.schema.index({organizationId: 1, reference: 1}, {unique: true});

  async function authorize(req, res, write = false) {
    const org = await Organization.findById(req.params.orgId);
    if (!org) { res.status(404).json({error: 'Business workspace not found'}); return null; }
    const isOwner = String(org.ownerId) === String(req.user._id);
    const member = (org.members || []).find(item => String(item.userId) === String(req.user._id));
    const role = isOwner ? 'owner' : String(member?.role || 'viewer');
    if (!canUsePosRole(role)) { res.status(403).json({error: 'POS access requires owner, manager, sales or finance permission'}); return null; }
    if (write && !['owner', 'admin', 'manager', 'sales'].includes(role)) { res.status(403).json({error: 'Sales permission is required to create a POS charge'}); return null; }
    req.posOrganization = org;
    return org;
  }

  // Configure the merchant's own Till/Paybill details. These are payment instructions, not
  // platform Daraja credentials; the merchant must ensure the account is active with Safaricom.
  app.put('/api/business/organizations/:orgId/pos/payment-profile', auth, async (req, res) => {
    try {
      const org = await authorize(req, res, true);
      if (!org) return;
      if (String(org.ownerId) !== String(req.user._id) && !['admin', 'manager'].includes(String(req.businessRole || ''))) {
        const member = (org.members || []).find(item => String(item.userId) === String(req.user._id));
        if (!['admin', 'manager'].includes(String(member?.role || ''))) return res.status(403).json({error: 'Manager permission is required to configure payment details'});
      }
      const profile = normalizeMerchantPaymentProfile(req.body || {});
      org.settings = {...(org.settings || {}), posPaymentProfile: profile};
      await org.save();
      return res.json({paymentProfile: profile});
    } catch (error) { return res.status(400).json({error: error.message || 'Invalid merchant payment profile'}); }
  });

  app.get('/api/business/organizations/:orgId/pos/payment-profile', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    return res.json({paymentProfile: org.settings?.posPaymentProfile || null});
  });

  // Create a cashier-generated charge and QR payload. The QR is an instruction to pay the
  // merchant directly. The app intentionally does not mark this paid: only a trusted Safaricom
  // C2B/STK callback or verified provider reconciliation may confirm funds received.
  app.post('/api/business/organizations/:orgId/pos/charges', auth, async (req, res) => {
    try {
      const org = await authorize(req, res, true);
      if (!org) return;
      const profile = org.settings?.posPaymentProfile;
      if (!profile) return res.status(409).json({error: 'Configure the shop Till or Paybill in POS payment settings first'});
      const charge = buildPosCharge({organization: org, amount: req.body?.amount, description: req.body?.description, reference: req.body?.reference, profile});
      charge.organizationId = org._id;
      charge.createdBy = req.user._id;
      const saved = await Charge.create(charge);
      return res.status(201).json({charge: {paymentId: saved.paymentId, reference: saved.reference, amount: saved.amount, currency: saved.currency, description: saved.description, method: saved.method, destination: saved.destination, qrPayload: saved.qrPayload, status: saved.status, createdAt: saved.createdAt}, notice: 'Customer pays this merchant using the displayed Till/Paybill instructions. Status remains PENDING until a trusted provider confirmation is connected.'});
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({error: 'That payment reference already exists. Create a new reference.'});
      return res.status(400).json({error: error.message || 'Could not create POS charge'});
    }
  });

  app.get('/api/business/organizations/:orgId/pos/charges', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    const status = ['PENDING', 'SUCCESS', 'FAILED', 'CANCELLED'].includes(String(req.query.status || '').toUpperCase()) ? String(req.query.status).toUpperCase() : null;
    const filter = {organizationId: org._id, ...(status ? {status} : {})};
    const charges = await Charge.find(filter).sort({createdAt: -1}).limit(100).lean();
    return res.json({charges});
  });
}
