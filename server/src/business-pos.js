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
  return {method, tillNumber: method === 'mpesa_till' ? tillNumber : '', paybillNumber: method === 'mpesa_paybill' ? paybillNumber : '', accountNumber: method === 'mpesa_paybill' ? accountNumber : ''};
}

export function buildPosCharge({organization, amount, description, reference, profile}) {
  const total = Number(amount);
  if (!Number.isSafeInteger(total) || total < 1 || total > 150000) throw new Error('Amount must be a whole number between KSh 1 and KSh 150,000');
  const title = String(description || '').trim().replace(/\s+/g, ' ').slice(0, 120);
  if (!title) throw new Error('Enter a sale description');
  const cleanedReference = String(reference || '').trim().replace(/\s+/g, '-').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 20);
  const paymentReference = cleanedReference || randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
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

export function registerBusinessPosRoutes({app, auth, mongoose, mpesaProvider}) {
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
    qrProvider: {type: String, enum: ['chatify_instructions', 'safaricom_dynamic_qr'], default: 'chatify_instructions'},
    dynamicQrImage: {type: String, default: null},
    dynamicQrRequestId: {type: String, default: null},
    status: {type: String, enum: ['PENDING', 'SUCCESS', 'FAILED', 'CANCELLED'], default: 'PENDING', index: true},
    confirmationSource: {type: String, default: null},
    providerReceipt: {type: String, default: null},
    confirmedAt: Date,
  }, {timestamps: true}));
  Charge.schema.index({organizationId: 1, reference: 1}, {unique: true});
  // Only actual receipt strings participate in uniqueness; many pending charges have no receipt.
  Charge.schema.index({providerReceipt: 1}, {unique: true, partialFilterExpression: {providerReceipt: {$type: 'string'}}});

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
      // Use Safaricom's actual M-Pesa-readable Dynamic QR when live/sandbox Daraja
      // credentials are configured. Mock mode remains clearly labelled instructions.
      if (mpesaProvider && !mpesaProvider.isMock) {
        if (typeof mpesaProvider.generateDynamicQr !== 'function') {
          return res.status(503).json({error: 'Dynamic QR is not available from the configured payment provider'});
        }
        const qr = await mpesaProvider.generateDynamicQr({
          merchantName: org.name,
          reference: charge.reference,
          amount: charge.amount,
          shortcode: profile.method === 'mpesa_till' ? profile.tillNumber : profile.paybillNumber,
          transactionCode: profile.method === 'mpesa_till' ? 'BG' : 'PB',
        });
        charge.qrProvider = 'safaricom_dynamic_qr';
        charge.dynamicQrImage = qr.qrCode;
        charge.dynamicQrRequestId = qr.requestId;
      }
      const saved = await Charge.create(charge);
      return res.status(201).json({charge: {
        paymentId: saved.paymentId, reference: saved.reference, amount: saved.amount,
        currency: saved.currency, description: saved.description, method: saved.method,
        destination: saved.destination, qrPayload: saved.qrPayload, qrProvider: saved.qrProvider,
        dynamicQrImage: saved.dynamicQrImage, status: saved.status, createdAt: saved.createdAt,
      }, notice: saved.qrProvider === 'safaricom_dynamic_qr'
        ? 'Scan the Dynamic QR with the M-Pesa app. Status remains pending until the merchant payment confirmation is matched.'
        : 'Demo/instruction QR only: customer must pay the merchant manually. Status remains pending until trusted provider confirmation is connected.'});
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({error: 'That payment reference already exists. Create a new reference.'});
      if (String(error?.stage || '').startsWith('qr_') && error.stage !== 'qr_validation') {
        return res.status(502).json({error: error.message || 'Safaricom Dynamic QR request failed. No payment request was saved.'});
      }
      return res.status(400).json({error: error.message || 'Could not create POS charge'});
    }
  });

  app.get('/api/business/organizations/:orgId/pos/charges', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    const status = ['PENDING', 'SUCCESS', 'FAILED', 'CANCELLED'].includes(String(req.query.status || '').toUpperCase()) ? String(req.query.status).toUpperCase() : null;
    const filter = {organizationId: org._id, ...(status ? {status} : {})};
    const charges = await Charge.find(filter).select('-qrPayload -dynamicQrImage').sort({createdAt: -1}).limit(100).lean();
    return res.json({charges});
  });

  app.get('/api/business/organizations/:orgId/pos/charges/:paymentId', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    const charge = await Charge.findOne({organizationId: org._id, paymentId: String(req.params.paymentId || '')}).lean();
    if (!charge) return res.status(404).json({error: 'POS payment request not found'});
    return res.json({charge});
  });

  // Manual reconciliation is available only to finance/management staff after they
  // independently verify the receipt in the merchant's official M-Pesa account/statement.
  // It is explicitly labelled manual and is never triggered by a customer screenshot.
  app.post('/api/business/organizations/:orgId/pos/charges/:paymentId/reconcile', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    const isOwner = String(org.ownerId) === String(req.user._id);
    const member = (org.members || []).find(item => String(item.userId) === String(req.user._id));
    const role = isOwner ? 'owner' : String(member?.role || 'viewer');
    if (!['owner', 'admin', 'manager', 'finance'].includes(role)) {
      return res.status(403).json({error: 'Only management or finance staff can reconcile a merchant receipt'});
    }
    const receipt = String(req.body?.receipt || '').trim().toUpperCase();
    if (req.body?.verified !== true || !/^[A-Z0-9]{6,40}$/.test(receipt)) {
      return res.status(400).json({error: 'Confirm official statement verification and enter a valid M-Pesa receipt number'});
    }
    try {
      const charge = await Charge.findOneAndUpdate({
        organizationId: org._id,
        paymentId: String(req.params.paymentId || ''),
        status: 'PENDING',
        providerReceipt: {$in: [null, '']},
      }, {$set: {
        status: 'SUCCESS',
        providerReceipt: receipt,
        confirmationSource: 'manual_merchant_reconciliation',
        confirmedAt: new Date(),
      }}, {new: true});
      if (!charge) return res.status(409).json({error: 'Payment is not pending, does not exist, or has already been reconciled'});
      return res.json({charge: {paymentId: charge.paymentId, reference: charge.reference, status: charge.status, providerReceipt: charge.providerReceipt, confirmationSource: charge.confirmationSource, confirmedAt: charge.confirmedAt}});
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({error: 'That M-Pesa receipt has already been used for another sale'});
      console.error('Manual POS reconciliation failed');
      return res.status(500).json({error: 'Could not reconcile the payment'});
    }
  });

  // Safaricom C2B callbacks are not cryptographically signed. Protect this endpoint
  // with a long random URL token and optionally enforce a network allowlist at the proxy.
  // Only Paybill transactions with exact shortcode, reference, amount and unique receipt
  // are auto-confirmed. Buy Goods callbacks may omit BillRefNumber, so those stay pending
  // until a merchant performs provider-side reconciliation rather than guessing by amount.
  app.post('/api/business/pos/c2b/confirmation/:token', async (req, res) => {
    const expected = process.env.POS_C2B_CALLBACK_TOKEN || '';
    if (expected.length < 32 || req.params.token !== expected) return res.status(404).json({error: 'Not found'});
    const allowed = String(process.env.POS_C2B_ALLOWED_IPS || '').split(',').map(value => value.trim()).filter(Boolean);
    if (allowed.length && !allowed.includes(String(req.ip || '').replace(/^::ffff:/, ''))) {
      return res.status(403).json({error: 'Callback source is not allowed'});
    }
    const body = req.body || {};
    const receipt = String(body.TransID || '').trim().slice(0, 40);
    const shortcode = String(body.BusinessShortCode || '').trim();
    const reference = String(body.BillRefNumber || '').trim().slice(0, 32);
    const amount = Number(body.TransAmount);
    if (!receipt || !/^\d{5,10}$/.test(shortcode) || !Number.isSafeInteger(amount) || amount < 1 || !reference) {
      return res.status(200).json({ResultCode: 0, ResultDesc: 'Received; no matching Paybill sale was confirmed'});
    }
    try {
      const charge = await Charge.findOneAndUpdate({
        method: 'mpesa_paybill',
        status: 'PENDING',
        amount,
        reference,
        'destination.paybillNumber': shortcode,
        providerReceipt: {$in: [null, '']},
      }, {$set: {
        status: 'SUCCESS',
        providerReceipt: receipt,
        confirmationSource: 'safaricom_c2b',
        confirmedAt: new Date(),
      }}, {new: true});
      // Unique providerReceipt prevents a single M-Pesa receipt paying multiple sales.
      if (!charge && await Charge.exists({providerReceipt: receipt})) {
        return res.status(200).json({ResultCode: 0, ResultDesc: 'Duplicate receipt ignored'});
      }
      return res.status(200).json({ResultCode: 0, ResultDesc: charge ? 'Payment confirmed' : 'Received; no exact matching Paybill sale'});
    } catch (error) {
      if (error?.code === 11000) return res.status(200).json({ResultCode: 0, ResultDesc: 'Duplicate receipt ignored'});
      console.error('POS C2B confirmation could not be processed');
      return res.status(500).json({ResultCode: 1, ResultDesc: 'Confirmation could not be processed'});
    }
  });
}
