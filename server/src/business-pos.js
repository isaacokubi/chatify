// Chatify in-person POS payment intents for shops, supermarkets, malls and hospitality.
import {randomUUID, createCipheriv, createDecipheriv, randomBytes} from 'node:crypto';
import {createDarajaProvider, normalizeMpesaPhone, calculatePaymentTotal} from './payments.js';

// Merchant Daraja secrets are encrypted at rest with a deployment-managed 32-byte key.
function posEncryptionKey() {
  const raw = String(process.env.POS_DARAJA_ENCRYPTION_KEY || '').trim();
  let key;
  if (/^[a-f0-9]{64}$/i.test(raw)) key = Buffer.from(raw, 'hex');
  else { try { key = Buffer.from(raw, 'base64'); } catch { key = null; } }
  if (!key || key.length !== 32) throw new Error('POS_DARAJA_ENCRYPTION_KEY must be a 32-byte key encoded as 64 hex characters or base64');
  return key;
}
export function encryptMerchantCredentials(credentials, key = posEncryptionKey()) {
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(credentials), 'utf8'), cipher.final()]);
  return `${iv.toString('base64')}.${cipher.getAuthTag().toString('base64')}.${ciphertext.toString('base64')}`;
}
export function decryptMerchantCredentials(value, key = posEncryptionKey()) {
  const [ivText, tagText, ciphertextText] = String(value || '').split('.');
  if (!ivText || !tagText || !ciphertextText) throw new Error('Merchant Daraja credentials are unavailable');
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(ivText, 'base64'));
  decipher.setAuthTag(Buffer.from(tagText, 'base64'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(ciphertextText, 'base64')), decipher.final()]).toString('utf8'));
}
export function validateMerchantDarajaCredentials(input, profile) {
  const mode = String(input?.mode || '').trim();
  const consumerKey = String(input?.consumerKey || '').trim();
  const consumerSecret = String(input?.consumerSecret || '').trim();
  const passkey = String(input?.passkey || '').trim();
  const shortcode = String(input?.shortcode || '').trim();
  const expectedShortcode = profile?.method === 'mpesa_till' ? profile.tillNumber : profile?.paybillNumber;
  if (!['sandbox', 'production'].includes(mode)) throw new Error('Choose sandbox or production Daraja credentials');
  if (!consumerKey || !consumerSecret || !passkey) throw new Error('Merchant consumer key, consumer secret and passkey are required');
  if (!/^\d{5,10}$/.test(shortcode) || shortcode !== expectedShortcode) throw new Error('Daraja shortcode must exactly match this merchant\'s configured Till or Paybill');
  return {mode, consumerKey, consumerSecret, passkey, shortcode};
}


export function resolvePosStkCallbackOutcome(callback, charge) {
  if (!callback || !charge || !/^-?\d+$/.test(String(callback.ResultCode))) return {error: 'malformed'};
  const resultCode = Number(callback.ResultCode);
  if (!Number.isSafeInteger(resultCode)) return {error: 'malformed'};
  if (resultCode !== 0) return {status: resultCode === 1032 ? 'CANCELLED' : 'FAILED', resultCode, description: String(callback.ResultDesc || '').slice(0, 160)};
  const items = Array.isArray(callback.CallbackMetadata?.Item) ? callback.CallbackMetadata.Item : [];
  const value = name => items.find(item => item?.Name === name)?.Value;
  const amount = Number(value('Amount'));
  const phone = normalizeMpesaPhone(String(value('PhoneNumber') || ''));
  const receipt = String(value('MpesaReceiptNumber') || '').trim().toUpperCase();
  if (amount !== (charge.totalAmount ?? charge.amount) || !phone || phone !== charge.stkPhone || !/^[A-Z0-9]{6,40}$/.test(receipt)) return {error: 'mismatch'};
  return {status: 'SUCCESS', resultCode: 0, phone, receipt, description: String(callback.ResultDesc || '').slice(0, 160)};
}


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
  const baseAmount = Number(amount);
  if (!Number.isSafeInteger(baseAmount) || baseAmount < 1 || baseAmount > 150000) throw new Error('Amount must be a whole number between KSh 1 and KSh 150,000 before the platform fee');
  const fee = calculatePaymentTotal(baseAmount);
  const total = fee.totalAmount;
  const title = String(description || '').trim().replace(/\s+/g, ' ').slice(0, 120);
  if (!title) throw new Error('Enter a sale description');
  // Safaricom Dynamic QR RefNo is limited to 12 characters. Keep the stored sale
  // reference within the same limit so later C2B callbacks can match it exactly.
  const cleanedReference = String(reference || '').trim().replace(/\s+/g, '-').replace(/[^A-Za-z0-9_-]/g, '').replace(/-+/g, '-').slice(0, 12);
  const paymentReference = cleanedReference || randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
  const destination = profile.method === 'mpesa_till'
    ? {method: 'mpesa_till', tillNumber: profile.tillNumber}
    : {method: 'mpesa_paybill', paybillNumber: profile.paybillNumber, accountNumber: paymentReference};
  const paymentId = randomUUID();
  const qr = {version: 1, type: 'chatify_pos_payment', paymentId, merchantId: String(organization._id), merchantName: String(organization.name), reference: paymentReference, amount: total, baseAmount, platformFee: fee.platformFee, totalAmount: total, platformFeeRate: 0.5, description: title, currency: 'KES', ...destination};
  return {paymentId, organizationId: organization._id, reference: paymentReference, amount: baseAmount, baseAmount, platformFee: fee.platformFee, totalAmount: total, platformFeeRate: 0.5, platformFeeStatus: 'PENDING_PAYMENT', currency: 'KES', description: title, method: profile.method, destination, qrPayload: JSON.stringify(qr), status: 'PENDING', confirmationSource: null};
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
    baseAmount: {type: Number, required: true, min: 1, max: 150000},
    platformFee: {type: Number, required: true, min: 1, max: 750},
    totalAmount: {type: Number, required: true, min: 1, max: 150000},
    platformFeeRate: {type: Number, default: 0.5},
    platformFeeStatus: {type: String, enum: ['PENDING_PAYMENT', 'PENDING_SETTLEMENT', 'SETTLED'], default: 'PENDING_PAYMENT', index: true},
    currency: {type: String, enum: ['KES'], default: 'KES'},
    description: {type: String, required: true, maxlength: 120},
    method: {type: String, enum: POS_METHODS, required: true},
    destination: {type: mongoose.Schema.Types.Mixed, required: true},
    qrPayload: {type: String, required: true},
    qrProvider: {type: String, enum: ['chatify_instructions', 'safaricom_dynamic_qr'], default: 'chatify_instructions'},
    dynamicQrImage: {type: String, default: null},
    dynamicQrRequestId: {type: String, default: null},
    stkPhone: {type: String, default: null},
    checkoutRequestId: {type: String, default: null, index: true},
    merchantRequestId: {type: String, default: null},
    stkResultCode: {type: Number, default: null},
    stkResultDescription: {type: String, default: null},
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
      let encryptedCredentials = org.settings?.posDarajaCredentialsEncrypted || null;
      const credentialsProvided = ['consumerKey', 'consumerSecret', 'passkey', 'shortcode', 'mode'].some(key => Object.prototype.hasOwnProperty.call(req.body || {}, key));
      if (credentialsProvided) {
        const validated = validateMerchantDarajaCredentials(req.body, profile);
        // Validate the encryption key before persisting anything; raw secrets never enter org settings.
        encryptedCredentials = encryptMerchantCredentials(validated);
      } else if (org.settings?.posPaymentProfile?.method && (org.settings.posPaymentProfile.method !== profile.method || (profile.method === 'mpesa_till' ? org.settings.posPaymentProfile.tillNumber !== profile.tillNumber : org.settings.posPaymentProfile.paybillNumber !== profile.paybillNumber))) {
        encryptedCredentials = null; // Credentials are tied to the exact shortcode and cannot follow a destination change.
      }
      org.settings = {...(org.settings || {}), posPaymentProfile: profile, posDarajaCredentialsEncrypted: encryptedCredentials};
      await org.save();
      return res.json({paymentProfile: profile, darajaConfigured: Boolean(encryptedCredentials)});
    } catch (error) { return res.status(400).json({error: error.message || 'Invalid merchant payment profile'}); }
  });

  app.get('/api/business/organizations/:orgId/pos/payment-profile', auth, async (req, res) => {
    const org = await authorize(req, res);
    if (!org) return;
    return res.json({paymentProfile: org.settings?.posPaymentProfile || null, darajaConfigured: Boolean(org.settings?.posDarajaCredentialsEncrypted)});
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
          amount: charge.totalAmount ?? charge.amount,
          shortcode: profile.method === 'mpesa_till' ? profile.tillNumber : profile.paybillNumber,
          transactionCode: profile.method === 'mpesa_till' ? 'BG' : 'PB',
        });
        charge.qrProvider = 'safaricom_dynamic_qr';
        charge.dynamicQrImage = qr.qrCode;
        charge.dynamicQrRequestId = qr.requestId;
      }
      const saved = await Charge.create(charge);
      return res.status(201).json({charge: {
        paymentId: saved.paymentId, reference: saved.reference, amount: saved.amount, baseAmount: saved.baseAmount,
        platformFee: saved.platformFee, totalAmount: saved.totalAmount, platformFeeRate: saved.platformFeeRate,
        platformFeeStatus: saved.platformFeeStatus,
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


  // Initiate an STK prompt using the merchant's own shortcode and encrypted Daraja credentials.
  // This is deliberately separate from the platform-wide provider: the prompt must debit into
  // the merchant account selected in the POS profile, never Chatify's platform shortcode.
  app.post('/api/business/organizations/:orgId/pos/charges/:paymentId/stk', auth, async (req, res) => {
    try {
      const org = await authorize(req, res, true);
      if (!org) return;
      const charge = await Charge.findOne({organizationId: org._id, paymentId: String(req.params.paymentId || ''), status: 'PENDING'});
      if (!charge) return res.status(404).json({error: 'Pending POS payment not found'});
      if (charge.platformFee > 0 && req.body?.feeAcknowledged !== true) return res.status(400).json({error: 'Confirm the disclosed 0.5% fee before sending the customer STK prompt', baseAmount: charge.baseAmount ?? charge.amount, platformFee: charge.platformFee, totalAmount: charge.totalAmount ?? charge.amount, platformFeeRate: charge.platformFeeRate ?? 0.5});
      const encrypted = org.settings?.posDarajaCredentialsEncrypted;
      if (!encrypted) return res.status(409).json({error: 'Configure authorized merchant-specific Daraja credentials before sending STK Push'});
      const callbackToken = String(process.env.POS_STK_CALLBACK_TOKEN || '').trim();
      if (callbackToken.length < 32) return res.status(503).json({error: 'POS_STK_CALLBACK_TOKEN must be configured with at least 32 random characters'});
      const credentials = decryptMerchantCredentials(encrypted);
      const expectedShortcode = charge.method === 'mpesa_till' ? charge.destination.tillNumber : charge.destination.paybillNumber;
      if (credentials.shortcode !== expectedShortcode) return res.status(409).json({error: 'Merchant credentials no longer match this payment destination'});
      const phone = normalizeMpesaPhone(String(req.body?.phone || ''));
      if (!phone) return res.status(400).json({error: 'Enter a valid Kenyan M-Pesa phone number'});
      if (charge.checkoutRequestId) return res.status(409).json({error: 'An STK prompt has already been initiated for this charge'});
      const callbackUrl = `https://${new URL(process.env.POS_STK_PUBLIC_BASE_URL || '').host}/api/business/pos/stk/callback/${callbackToken}`;
      const baseUrl = new URL(process.env.POS_STK_PUBLIC_BASE_URL || '');
      if (baseUrl.protocol !== 'https:' || !baseUrl.hostname.includes('.') || baseUrl.username || baseUrl.password) return res.status(503).json({error: 'POS_STK_PUBLIC_BASE_URL must be a public HTTPS base URL'});
      const provider = createDarajaProvider({
        mode: credentials.mode, consumerKey: credentials.consumerKey, consumerSecret: credentials.consumerSecret,
        shortcode: credentials.shortcode, passkey: credentials.passkey, callbackUrl,
        transactionType: charge.method === 'mpesa_till' ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline',
      });
      // Claim the charge before contacting Daraja to prevent concurrent duplicate prompts.
      const claimed = await Charge.findOneAndUpdate({_id: charge._id, status: 'PENDING', checkoutRequestId: {$in: [null, '']}, confirmationSource: {$in: [null, '']}},
        {$set: {stkPhone: phone, confirmationSource: 'daraja_stk_pending'}}, {new: true});
      if (!claimed) return res.status(409).json({error: 'Another STK request is already in progress'});
      let result;
      try {
        result = await provider.initiate({paymentId: charge.paymentId, amount: charge.totalAmount ?? charge.amount, phone, description: charge.description});
      } catch (error) {
        // A transport timeout is ambiguous: Daraja may have accepted the request even if
        // our server never received its response. Keep the claim locked in that case so a
        // cashier cannot accidentally charge the customer twice. Explicit OAuth/provider
        // rejections are safe to release because no successful STK request was acknowledged.
        if (error?.stage !== 'stk_transport') {
          await Charge.updateOne(
            {_id: charge._id, status: 'PENDING', checkoutRequestId: {$in: [null, '']}, confirmationSource: 'daraja_stk_pending'},
            {$set: {stkResultDescription: 'STK initiation rejected; verify Daraja status before retrying', confirmationSource: null, stkPhone: null}}
          );
        } else {
          await Charge.updateOne(
            {_id: charge._id, status: 'PENDING', checkoutRequestId: {$in: [null, '']}, confirmationSource: 'daraja_stk_pending'},
            {$set: {stkResultDescription: 'STK outcome unknown after network timeout; do not retry until Daraja status is checked'}}
          );
        }
        return res.status(502).json({
          error: error?.stage === 'stk_transport'
            ? 'Daraja response timed out. The payment outcome is unknown; check Daraja status before retrying.'
            : (error.message || 'Daraja could not initiate the STK prompt'),
          outcomeUnknown: error?.stage === 'stk_transport',
        });
      }
      const saved = await Charge.findOneAndUpdate({_id: charge._id, status: 'PENDING', checkoutRequestId: {$in: [null, '']}},
        {$set: {checkoutRequestId: result.checkoutRequestId, merchantRequestId: result.merchantRequestId, confirmationSource: 'daraja_stk_pending'}}, {new: true});
      if (!saved) return res.status(409).json({error: 'Payment changed while Daraja was processing the request'});
      return res.status(202).json({paymentId: saved.paymentId, status: saved.status, checkoutRequestId: saved.checkoutRequestId, message: 'STK prompt sent. Payment remains pending until the matching Safaricom callback confirms success.'});
    } catch (error) {
      return res.status(400).json({error: error.message || 'Could not initiate merchant STK Push'});
    }
  });

  const PlatformFeeLedger = mongoose.models.PlatformFeeLedger || mongoose.model('PlatformFeeLedger', new mongoose.Schema({paymentId:{type:String,required:true,unique:true,index:true},source:{type:String,enum:['personal_request','business_pos'],required:true},businessOrganizationId:{type:O,index:true},baseAmount:{type:Number,required:true,min:1},feeAmount:{type:Number,required:true,min:1},totalAmount:{type:Number,required:true,min:1},currency:{type:String,default:'KES'},status:{type:String,enum:['PENDING_SETTLEMENT','SETTLED','REVERSED'],default:'PENDING_SETTLEMENT',index:true},providerReceipt:{type:String,default:null},confirmedAt:{type:Date,required:true}},{timestamps:true}));
  async function recordPosPlatformFee(charge, receipt) {
    // Pre-fee charges must remain untouched; only charges created with a recorded fee accrue one.
    if (!charge || !Number.isSafeInteger(charge.baseAmount) || !Number.isSafeInteger(charge.platformFee) || charge.platformFee < 1) return;
    await Charge.updateOne({_id:charge._id,status:'SUCCESS'},{$set:{platformFeeStatus:'PENDING_SETTLEMENT'}});
    await PlatformFeeLedger.updateOne({paymentId:charge.paymentId},{$setOnInsert:{paymentId:charge.paymentId,source:'business_pos',businessOrganizationId:charge.organizationId,baseAmount:charge.baseAmount,feeAmount:charge.platformFee,totalAmount:charge.totalAmount??charge.amount,currency:charge.currency||'KES',status:'PENDING_SETTLEMENT',providerReceipt:receipt,confirmedAt:charge.confirmedAt||new Date()}},{upsert:true});
  }

  // Only the merchant's own callback URL/token and exact provider request IDs can confirm a charge.
  // Amount, payer phone and result code are checked; duplicate callbacks cannot replay a receipt.
  app.post('/api/business/pos/stk/callback/:token', async (req, res) => {
    const expected = String(process.env.POS_STK_CALLBACK_TOKEN || '');
    if (expected.length < 32 || req.params.token !== expected) return res.status(404).json({error: 'Not found'});
    const cb = req.body?.Body?.stkCallback;
    if (!cb || typeof cb.CheckoutRequestID !== 'string' || typeof cb.MerchantRequestID !== 'string' || !/^-?\d+$/.test(String(cb.ResultCode))) return res.status(400).json({error: 'Malformed callback'});
    const charge = await Charge.findOne({checkoutRequestId: cb.CheckoutRequestID, merchantRequestId: cb.MerchantRequestID, status: 'PENDING', confirmationSource: 'daraja_stk_pending'});
    if (!charge) {
      // A previous callback may have marked the charge successful before a ledger write
      // failed. Rebuild the idempotent fee entry on duplicate delivery rather than losing it.
      const completed = await Charge.findOne({checkoutRequestId: cb.CheckoutRequestID, merchantRequestId: cb.MerchantRequestID, status: 'SUCCESS', providerReceipt: {$type: 'string'}});
      if (completed) await recordPosPlatformFee(completed, completed.providerReceipt);
      return res.json({ok: true, duplicate: true});
    }
    const outcome = resolvePosStkCallbackOutcome(cb, charge);
    if (outcome.error === 'malformed') return res.status(400).json({error: 'Malformed result code'});
    if (outcome.error === 'mismatch') return res.status(400).json({error: 'Callback amount, phone or receipt did not match the initiated merchant payment'});
    if (outcome.status === 'SUCCESS') {
      try {
        const updated = await Charge.findOneAndUpdate({_id: charge._id, status: 'PENDING', checkoutRequestId: cb.CheckoutRequestID, merchantRequestId: cb.MerchantRequestID, providerReceipt: {$in: [null, '']}},
          {$set: {status: 'SUCCESS', providerReceipt: outcome.receipt, stkResultCode: 0, stkResultDescription: outcome.description, confirmationSource: 'safaricom_stk_callback', confirmedAt: new Date()}}, {new: true});
        if (!updated && await Charge.exists({providerReceipt: outcome.receipt})) { const existing=await Charge.findOne({providerReceipt:outcome.receipt}); if(existing) await recordPosPlatformFee(existing, outcome.receipt); return res.json({ok: true, duplicate: true}); }
        if (updated) await recordPosPlatformFee(updated, outcome.receipt);
        return res.json({ok: true, confirmed: Boolean(updated)});
      } catch (error) {
        if (error?.code === 11000) return res.json({ok: true, duplicate: true});
        return res.status(500).json({error: 'Could not process payment confirmation'});
      }
    }
    await Charge.findOneAndUpdate({_id: charge._id, status: 'PENDING', checkoutRequestId: cb.CheckoutRequestID, merchantRequestId: cb.MerchantRequestID},
      {$set: {status: outcome.status, stkResultCode: outcome.resultCode, stkResultDescription: outcome.description, confirmationSource: 'safaricom_stk_callback', confirmedAt: new Date()}});
    return res.json({ok: true});
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
      await recordPosPlatformFee(charge, receipt);
      return res.json({charge: {paymentId: charge.paymentId, reference: charge.reference, status: charge.status, providerReceipt: charge.providerReceipt, confirmationSource: charge.confirmationSource, confirmedAt: charge.confirmedAt}});
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({error: 'That M-Pesa receipt has already been used for another sale'});
      console.error('Manual POS reconciliation failed');
      return res.status(500).json({error: 'Could not reconcile the payment'});
    }
  });

  // Safaricom C2B callbacks are not cryptographically signed. Protect this endpoint
  // with a long random URL token and optionally enforce a network allowlist at the proxy.
  // Exact-reference Paybill transactions are auto-confirmed. Buy Goods/Till callbacks are
  // also supported only if Safaricom supplies the matching reference; otherwise stay pending
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
        $or: [
          {method: 'mpesa_paybill', 'destination.paybillNumber': shortcode},
          {method: 'mpesa_till', 'destination.tillNumber': shortcode},
        ],
        status: 'PENDING',
        $and: [{$or: [{totalAmount: amount}, {totalAmount: {$exists: false}, amount}]}],
        reference,
        providerReceipt: {$in: [null, '']},
      }, {$set: {
        status: 'SUCCESS',
        providerReceipt: receipt,
        confirmationSource: 'safaricom_c2b',
        confirmedAt: new Date(),
      }}, {new: true});
      // Unique providerReceipt prevents a single M-Pesa receipt paying multiple sales.
      if (!charge && await Charge.exists({providerReceipt: receipt})) {
        const existing = await Charge.findOne({providerReceipt: receipt});
        if (existing) await recordPosPlatformFee(existing, receipt);
        return res.status(200).json({ResultCode: 0, ResultDesc: 'Duplicate receipt ignored'});
      }
      if (charge) await recordPosPlatformFee(charge, receipt);
      return res.status(200).json({ResultCode: 0, ResultDesc: charge ? 'Payment confirmed' : 'Received; no exact matching Paybill sale'});
    } catch (error) {
      if (error?.code === 11000) return res.status(200).json({ResultCode: 0, ResultDesc: 'Duplicate receipt ignored'});
      console.error('POS C2B confirmation could not be processed');
      return res.status(500).json({ResultCode: 1, ResultDesc: 'Confirmation could not be processed'});
    }
  });
}
