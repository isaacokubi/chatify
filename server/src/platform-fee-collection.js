// Collect Chatify's disclosed platform fee separately from the merchant/school payment.
// Safaricom STK Push does not split one payment between two shortcodes, so this module
// starts a second STK Push to the platform-owned Paybill/Till after the base payment succeeds.
// Fees remain pending until this separate STK callback confirms amount, phone and receipt.
import { normalizeMpesaPhone } from './payments.js';

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
