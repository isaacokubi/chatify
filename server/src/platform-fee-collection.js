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
    const base = String(env.PUBLIC_API_URL || env.API_URL || '').trim();
    if (!base) throw new Error('PUBLIC_API_URL or API_URL must be configured for platform fee callbacks');
    const url = new URL('/api/payments/platform-fee/callback', base.replace(/\/$/, ''));
    if (url.protocol !== 'https:') throw new Error('Platform fee callback URL must use HTTPS');
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
    return createDarajaProvider({mode, consumerKey, consumerSecret, shortcode, passkey, callbackUrl(), transactionType:settings.walletType === 'mpesa_till' ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline'});
  };

  async function collect({paymentId, source, payerPhone, baseAmount, feeAmount}) {
    const phone = normalizeMpesaPhone(String(payerPhone || ''));
    if (!phone) throw new Error('A verified Kenyan payer phone is required for the separate platform-fee prompt');
    if (!Number.isSafeInteger(baseAmount) || baseAmount < 1 || !Number.isSafeInteger(feeAmount) || feeAmount < 1) throw new Error('Invalid platform fee collection amount');
    const existing = await Collection.findOne({paymentId});
    if (existing) return existing.toObject();
    const settings = await providerConfig();
    if (!settings || settings.enabled === false) throw new Error('Platform fee collection is disabled');
    const walletNumber = settings.walletType === 'mpesa_paybill' ? settings.paybillNumber : settings.walletType === 'mpesa_till' ? settings.tillNumber : '';
    const record = await Collection.create({paymentId, source, payerPhone:phone, baseAmount, feeAmount, walletType:settings.walletType, walletNumber, accountReference:settings.accountReference || 'CHATIFY-FEE'});
    try {
      const provider = providerFor(settings);
      const refs = await provider.initiate({paymentId:('FEE'+paymentId).replace(/[^A-Za-z0-9]/g,'').slice(-12), amount:feeAmount, phone, description:'Chatify fee'});
      const updated = await Collection.findOneAndUpdate({_id:record._id,status:'PENDING_INITIATION'},{$set:{status:'PENDING',checkoutRequestId:refs.checkoutRequestId,merchantRequestId:refs.merchantRequestId}},{new:true});
      return updated?.toObject() || record.toObject();
    } catch (error) {
      await Collection.updateOne({_id:record._id,status:'PENDING_INITIATION'},{$set:{status:'FAILED',resultDescription:String(error?.message || 'Fee STK initiation failed').slice(0,160)}});
      throw error;
    }
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
    if (Ledger) await Ledger.updateOne({paymentId:record.paymentId},{$set:{status:'SETTLED',providerReceipt:receipt}});
    const Payment = mongoose.models.Payment;
    if (Payment) await Payment.updateOne({paymentId:record.paymentId,platformFee:record.feeAmount},{$set:{platformFeeStatus:'SETTLED'}});
    const Charge = mongoose.models.BusinessPosCharge;
    if (Charge) await Charge.updateOne({paymentId:record.paymentId,platformFee:record.feeAmount},{$set:{platformFeeStatus:'SETTLED'}});
    return {settled:true};
  }
  return {collect, processCallback, Collection};
}
