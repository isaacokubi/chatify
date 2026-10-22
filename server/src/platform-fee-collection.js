// Collect Chatify's disclosed platform fee separately from the merchant/school payment.
// Safaricom STK Push does not split one payment between two shortcodes, so this module
// starts a second STK Push to the platform-owned Paybill/Till after the base payment succeeds.
// Fees remain pending until this separate STK callback confirms amount, phone and receipt.
import { createDarajaProvider, normalizeMpesaPhone } from './payments.js';

export function createPlatformFeeCollector({ mongoose, env = process.env }) {
  const O = mongoose.Schema.Types.ObjectId;
  const Collection = mongoose.models.PlatformFeeCollection || mongoose.model('PlatformFeeCollection', new mongoose.Schema({
    paymentId: {type:String, required:true, unique:true, index:true},
    source: {type:String, enum:['business_checkout','business_pos','school_fee'], required:true},
    payerPhone: {type:String, required:true},
    baseAmount: {type:Number, required:true, min:1},
    feeAmount: {type:Number, required:true, min:1},
    walletType: {type:String, enum:['mpesa_paybill','mpesa_till'], required:true},
    walletNumber: {type:String, required:true},
    accountReference: {type:String, default:'CHATIFY-FEE'},
    status: {type:String, enum:['PENDING_INITIATION','PENDING','SETTLED','FAILED','CANCELLED','NEEDS_REVIEW'], default:'PENDING_INITIATION', index:true},
    checkoutRequestId: {type:String, sparse:true, unique:true},
    merchantRequestId: {type:String},
    providerReceipt: {type:String, default:null},
    resultCode: Number,
    resultDescription: {type:String, maxlength:160},
    callbackProcessedAt: Date,
  }, {timestamps:true}));
  Collection.schema.index({status:1, createdAt:-1});

  const settingsModel = () => mongoose.models.PlatformFeeSettings;
  const providerConfig = () => {
    const settingsModelRef = settingsModel();
    if (!settingsModelRef) throw new Error('Platform fee settings are not registered');
    return settingsModelRef.findOne({key:'global'}).lean();
  };
  const callbackUrl = () => {
    const configured = String(env.PLATFORM_FEE_MPESA_CALLBACK_URL || '').trim();
    const base = String(env.PUBLIC_API_URL || env.API_URL || '').trim();
    if (!configured && !base) throw new Error('Set PLATFORM_FEE_MPESA_CALLBACK_URL or PUBLIC_API_URL/API_URL for platform fee callbacks');
    const url = configured ? new URL(configured) : new URL('/api/payments/platform-fee/callback', base.replace(/\/$/, ''));
    if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/api/payments/platform-fee/callback') throw new Error('Platform fee callback URL must be HTTPS and point to /api/payments/platform-fee/callback');
    return url.toString();
  };
  const providerFor = (settings) => {
    const mode = String(env.PLATFORM_FEE_MPESA_ENV || '').trim();
    const consumerKey = String(env.PLATFORM_FEE_MPESA_CONSUMER_KEY || '').trim();
    const consumerSecret = String(env.PLATFORM_FEE_MPESA_CONSUMER_SECRET || '').trim();
    const passkey = String(env.PLATFORM_FEE_MPESA_PASSKEY || '').trim();
    const shortcode = String(env.PLATFORM_FEE_MPESA_SHORTCODE || '').trim();
    if (!['sandbox','production'].includes(mode) || !consumerKey || !consumerSecret || !passkey || !/^\d{5,10}$/.test(shortcode)) {
      throw new Error('Platform-owned Daraja credentials are incomplete');
    }
    const walletNumber = settings.walletType === 'mpesa_paybill' ? settings.paybillNumber : settings.walletType === 'mpesa_till' ? settings.tillNumber : '';
    if (!walletNumber || !['mpesa_paybill','mpesa_till'].includes(settings.walletType)) {
      throw new Error('Automatic collection requires a platform Paybill or Till. Phone wallets require a separately approved B2C payout flow.');
    }
    if (shortcode !== walletNumber) throw new Error('PLATFORM_FEE_MPESA_SHORTCODE must match the configured platform wallet number');
    if (env.NODE_ENV === 'production' && mode !== 'production') throw new Error('Production fee collection requires PLATFORM_FEE_MPESA_ENV=production');
    return createDarajaProvider({mode, consumerKey, consumerSecret, shortcode, passkey, callbackUrl:callbackUrl(), transactionType:settings.walletType === 'mpesa_till' ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline'});
  };

  // Chatify monetizes workspaces through setup and recurring subscription fees.
  // New business, school and POS payments never trigger a separate platform-fee STK prompt.
  // Keep this compatibility method so older route modules can call it without charging.
  async function collect({paymentId, source, baseAmount}) {
    return {paymentId, source, status:'NOT_APPLICABLE', feeAmount:0, baseAmount};
  }

  async function processCallback(callback) {
    if (!callback || typeof callback.CheckoutRequestID !== 'string' || typeof callback.MerchantRequestID !== 'string') return {error:'malformed'};
    const record = await Collection.findOne({checkoutRequestId:callback.CheckoutRequestID,merchantRequestId:callback.MerchantRequestID});
    if (!record) return {ignored:true};
    if (record.callbackProcessedAt || ['SETTLED','FAILED','CANCELLED','NEEDS_REVIEW'].includes(record.status)) return {duplicate:true};
    if (!/^-?\d+$/.test(String(callback.ResultCode))) return {error:'malformed'};
    const now = new Date();
    const code = Number(callback.ResultCode);
    if (code !== 0) {
      const status = code === 1032 ? 'CANCELLED' : 'FAILED';
      await Collection.updateOne({_id:record._id,status:'PENDING',callbackProcessedAt:{$exists:false}},{$set:{status,resultCode:code,resultDescription:String(callback.ResultDesc||'').slice(0,160),callbackProcessedAt:now}});
      return {status};
    }
    const items = Array.isArray(callback.CallbackMetadata?.Item) ? callback.CallbackMetadata.Item : [];
    const value = name => items.find(item => item?.Name === name)?.Value;
    const amount = Number(value('Amount'));
    const phone = normalizeMpesaPhone(String(value('PhoneNumber') || ''));
    const receipt = String(value('MpesaReceiptNumber') || '').trim().toUpperCase();
    if (amount !== record.feeAmount || phone !== record.payerPhone || !/^[A-Z0-9]{6,40}$/.test(receipt)) {
      await Collection.updateOne({_id:record._id,status:'PENDING',callbackProcessedAt:{$exists:false}},{$set:{status:'NEEDS_REVIEW',resultCode:code,resultDescription:'Successful callback amount, phone or receipt did not match expected values',callbackProcessedAt:now}});
      return {rejected:true};
    }
    const settled = await Collection.findOneAndUpdate({_id:record._id,status:'PENDING',callbackProcessedAt:{$exists:false}},{$set:{status:'SETTLED',providerReceipt:receipt,resultCode:0,resultDescription:'Fee collection confirmed',callbackProcessedAt:now}},{new:true});
    if (!settled) return {duplicate:true};
    // Update the shared reconciliation ledger only after Safaricom confirms this fee receipt.
    const Ledger = mongoose.models.PlatformFeeLedger;
    if (Ledger) await Ledger.updateOne({paymentId:record.paymentId},{$set:{status:'SETTLED',providerReceipt:receipt},$setOnInsert:{paymentId:record.paymentId,source:record.source,businessOrganizationId:undefined,baseAmount:record.baseAmount,feeAmount:record.feeAmount,totalAmount:record.baseAmount+record.feeAmount,currency:'KES',confirmedAt:now}},{upsert:true});
    const Payment = mongoose.models.Payment;
    if (Payment) await Payment.updateOne({paymentId:record.paymentId,platformFee:record.feeAmount},{$set:{platformFeeStatus:'SETTLED'}});
    const Charge = mongoose.models.BusinessPosCharge;
    if (Charge) await Charge.updateOne({paymentId:record.paymentId,platformFee:record.feeAmount},{$set:{platformFeeStatus:'SETTLED'}});
    return {settled:true};
  }
  return {collect, processCallback, Collection};
}
