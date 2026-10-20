import {randomUUID} from 'node:crypto';
import {isIP} from 'node:net';

export const PAYMENT_STATUSES = Object.freeze(['PENDING', 'SUCCESS', 'FAILED', 'CANCELLED']);
export const MAX_PAYMENT_AMOUNT = 150000;
export const PLATFORM_FEE_BASIS_POINTS = 50; // 0.50% of the pre-fee amount.

// M-Pesa amounts are whole KSh. Round the disclosed fee up to the next shilling
// so the platform never silently charges less than the configured 0.50% rate.
export function calculatePlatformFee(amount, feeRate = 0.5) {
  if (!Number.isSafeInteger(amount) || amount < 1) throw new Error('Fee base must be a positive whole KSh amount');
  if (!Number.isFinite(feeRate) || feeRate < 0 || feeRate > 5) throw new Error('Platform fee rate must be between 0 and 5 percent');
  if (feeRate === 0) return 0;
  // Convert the percentage to basis points and round up to a whole KSh for M-Pesa.
  return Math.ceil((amount * feeRate * 100) / 10000);
}

// Calculate the amount payable for a category that explicitly opts into the platform fee.
 // Personal transfers must call this with applicable:false (or use no fee fields).
export function calculatePaymentTotal(amount, {applicable = true, feeRate = 0.5} = {}) {
  if (!Number.isSafeInteger(amount) || amount < 1 || amount > MAX_PAYMENT_AMOUNT) {
    throw new Error(`Payment base must be a positive whole-KSh amount no greater than KSh ${MAX_PAYMENT_AMOUNT}`);
  }
  // Keep ordinary transfers fee-free; Safaricom's own charges are separate provider charges.
  if (!applicable || feeRate === 0) {
    return {baseAmount: amount, platformFee: 0, totalAmount: amount, platformFeeRate: 0, platformFeeStatus: 'NOT_APPLICABLE'};
  }
  // Only opted-in business/school-fee workflows calculate the configured platform fee.
  const platformFee = calculatePlatformFee(amount, feeRate);
  const totalAmount = amount + platformFee;
  if (!Number.isSafeInteger(totalAmount) || totalAmount > MAX_PAYMENT_AMOUNT) {
    throw new Error(`Amount plus the 0.5% platform fee must not exceed KSh ${MAX_PAYMENT_AMOUNT}`);
  }
  return {baseAmount: amount, platformFee, totalAmount, platformFeeRate: feeRate, platformFeeStatus: 'PENDING_PAYMENT'};
}

export function normalizeMpesaPhone(value) {
  if (typeof value !== 'string') return null;
  const digits = value.trim().replace(/[\s()+-]/g, '');
  if (/^0[17]\d{8}$/.test(digits)) return `254${digits.slice(1)}`;
  if (/^\+?254[17]\d{8}$/.test(digits)) return digits.replace(/^\+/, '');
  return null;
}

export function validPaymentAmount(value) {
  return Number.isSafeInteger(value) && value > 0 && value <= MAX_PAYMENT_AMOUNT;
}

export function darajaTimestamp(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-GB', {timeZone:'Africa/Nairobi',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(date);
  const value = type => parts.find(part => part.type === type)?.value || '';
  return `${value('year')}${value('month')}${value('day')}${value('hour')}${value('minute')}${value('second')}`;
}

export function createMockMpesaProvider() {
  return {
    name: 'mock',
    isMock: true,
    async initiate({paymentId}) {
      return {checkoutRequestId: `MOCK-${paymentId}`, merchantRequestId: `MOCK-MERCHANT-${paymentId}`};
    },
  };
}

export function createDarajaProvider(config = {}, transport = globalThis.fetch) {
  const mode = config.mode || 'sandbox';
  if (!['sandbox', 'production'].includes(mode)) throw new Error('Invalid Daraja environment');
  const required = ['consumerKey', 'consumerSecret', 'shortcode', 'passkey', 'callbackUrl'];
  if (required.some(key => typeof config[key] !== 'string' || !config[key].trim())) {
    throw new Error('Daraja credentials and callback URL are required');
  }
  let callback;
  try { callback = new URL(config.callbackUrl); } catch { throw new Error('Daraja callback URL must be a public HTTPS URL'); }
  const hostname=callback.hostname.toLowerCase().replace(/^\[|\]$/g,'');
  const reservedHost=['localhost','local','internal','test','example','invalid','lan'].some(suffix=>hostname===suffix||hostname.endsWith(`.${suffix}`));
  if (callback.protocol !== 'https:' || callback.username || callback.password || isIP(hostname) || !hostname.includes('.') || reservedHost) throw new Error('Daraja callback URL must be a public HTTPS URL');
  if (typeof transport !== 'function') throw new Error('HTTP transport is unavailable');
  const host = mode === 'production' ? 'https://api.safaricom.co.ke' : 'https://sandbox.safaricom.co.ke';
  const type = config.transactionType || 'CustomerPayBillOnline';
  if (!['CustomerPayBillOnline', 'CustomerBuyGoodsOnline'].includes(type)) throw new Error('Invalid Daraja transaction type');
  let cachedToken;
  let tokenExpiry = 0;
  async function token() {
    if (cachedToken && Date.now() < tokenExpiry) return cachedToken;
    const basic = Buffer.from(`${config.consumerKey}:${config.consumerSecret}`).toString('base64');
    let response;
    try {
      response = await transport(`${host}/oauth/v1/generate?grant_type=client_credentials`, {
        headers: {Authorization: `Basic ${basic}`}, signal: AbortSignal.timeout(10000),
      });
    } catch {
      throw Object.assign(new Error('Daraja OAuth network request failed'), {stage: 'oauth_transport'});
    }
    const data = await response.json().catch(() => ({}));
    if (!response.ok || typeof data.access_token !== 'string') {
      throw Object.assign(new Error('Daraja authentication failed'), {stage: 'oauth_auth'});
    }
    cachedToken = data.access_token;
    tokenExpiry = Date.now() + Math.max(0, Number(data.expires_in || 0) - 30) * 1000;
    return cachedToken;
  }
  return {
    name: `daraja-${mode}`,
    isMock: false,
    // Dynamic QR creates a Safaricom-readable Buy Goods/Paybill QR for the actual
    // merchant shortcode. Merchant numbers are data, never platform credentials.
    async generateDynamicQr({merchantName, reference, amount, shortcode, transactionCode}) {
      // Daraja Dynamic QR limits MerchantName to 20 characters and RefNo to 12.
      const merchant = String(merchantName || '').trim().slice(0, 20);
      const ref = String(reference || '').trim().slice(0, 12);
      const total = Number(amount);
      const cpi = String(shortcode || '').trim();
      if (!merchant || !ref || !Number.isSafeInteger(total) || total < 1 || total > MAX_PAYMENT_AMOUNT) {
        throw Object.assign(new Error('Invalid Dynamic QR merchant, reference or amount'), {stage: 'qr_validation'});
      }
      if (!/^\d{5,10}$/.test(cpi) || !['BG', 'PB'].includes(transactionCode)) {
        throw Object.assign(new Error('Invalid Dynamic QR merchant shortcode or transaction type'), {stage: 'qr_validation'});
      }
      const accessToken = await token();
      let response;
      try {
        response = await transport(`${host}/mpesa/qrcode/v1/generate`, {
          method: 'POST',
          headers: {Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json'},
          body: JSON.stringify({MerchantName: merchant, RefNo: ref, Amount: total, TrxCode: transactionCode, CPI: cpi, Size: '300'}),
          signal: AbortSignal.timeout(15000),
        });
      } catch {
        throw Object.assign(new Error('Daraja Dynamic QR network request failed'), {stage: 'qr_transport'});
      }
      const data = await response.json().catch(() => ({}));
      if (!response.ok || typeof data.QRCode !== 'string' || data.QRCode.length < 20) {
        throw Object.assign(new Error('Daraja rejected the Dynamic QR request'), {stage: 'qr_rejected'});
      }
      return {qrCode: data.QRCode, requestId: String(data.RequestID || '').slice(0, 100)};
    },
    async initiate({amount, phone, description, paymentId, now = new Date()}) {
      const timestamp = darajaTimestamp(now);
      const password = Buffer.from(`${config.shortcode}${config.passkey}${timestamp}`).toString('base64');
      const body = {
        BusinessShortCode: config.shortcode, Password: password, Timestamp: timestamp,
        TransactionType: type, Amount: amount, PartyA: phone, PartyB: config.shortcode,
        PhoneNumber: phone, CallBackURL: config.callbackUrl,
        // Daraja STK Push accepts at most 12 characters for AccountReference.
        AccountReference: paymentId.replace(/-/g, '').slice(-12),
        // Daraja STK Push limits TransactionDesc to 13 characters.
        TransactionDesc: description.slice(0, 13),
      };
      const accessToken = await token();
      let response;
      try {
        response = await transport(`${host}/mpesa/stkpush/v1/processrequest`, {
          method: 'POST', headers: {Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json'},
          body: JSON.stringify(body), signal: AbortSignal.timeout(15000),
        });
      } catch {
        throw Object.assign(new Error('Daraja STK network request failed'), {stage: 'stk_transport'});
      }
      const data = await response.json().catch(() => ({}));
      if (!response.ok || data.ResponseCode !== '0' || !data.CheckoutRequestID || !data.MerchantRequestID) {
        throw Object.assign(new Error('Daraja rejected the STK request'), {stage: 'stk_rejected'});
      }
      return {checkoutRequestId: data.CheckoutRequestID, merchantRequestId: data.MerchantRequestID};
    },
  };
}

export function resolveMpesaProvider(env = process.env, transport) {
  const configuredMode = env.MPESA_ENV?.trim();
  const mode = configuredMode || 'mock';
  if (env.NODE_ENV === 'production' && !configuredMode) {
    throw new Error('Production requires explicit MPESA_ENV=mock for a demo or MPESA_ENV=production for live Daraja payments');
  }
  if (env.NODE_ENV === 'production' && mode === 'sandbox') {
    throw new Error('MPESA_ENV=sandbox is not allowed in production; use mock for a demo or production for live Daraja payments');
  }
  if (mode === 'mock') return createMockMpesaProvider();
  if (mode !== 'sandbox' && mode !== 'production') throw new Error('MPESA_ENV must be mock, sandbox, or production');
  return createDarajaProvider({
    mode, consumerKey:env.MPESA_CONSUMER_KEY, consumerSecret:env.MPESA_CONSUMER_SECRET,
    shortcode:env.MPESA_SHORTCODE, passkey:env.MPESA_PASSKEY, callbackUrl:env.MPESA_CALLBACK_URL,
    transactionType:env.MPESA_TRANSACTION_TYPE,
  }, transport);
}

export const newPaymentId = () => randomUUID();

export function canAccessPayment(payment, userId, isConversationMember = true) {
  if (!payment || ![String(payment.requesterId), String(payment.payerId)].includes(String(userId))) return false;
  return !payment.conversationId || isConversationMember;
}

export function canCancelPayment(payment, userId, isConversationMember = true) {
  return canAccessPayment(payment, userId, isConversationMember) &&
    payment.status === 'PENDING' && !payment.initiatedAt && payment.initiating !== true;
}

export function canRetryPayment(payment, userId, isConversationMember = true) {
  return canAccessPayment(payment, userId, isConversationMember) &&
    String(payment.payerId) === String(userId) && ['FAILED','CANCELLED'].includes(payment.status);
}

export function resolveCallbackOutcome(callback, payment) {
  if (!callback || !payment || callback.ResultCode == null || !/^-?\d+$/.test(String(callback.ResultCode)) || !Number.isSafeInteger(Number(callback.ResultCode))) return {error:'malformed'};
  const items = Array.isArray(callback.CallbackMetadata?.Item) ? callback.CallbackMetadata.Item : [];
  const value = name => items.find(item => item?.Name === name)?.Value;
  const code = Number(callback.ResultCode);
  const expectedAmount = payment.feeCollectionMode === 'separate' ? (payment.baseAmount ?? payment.amount) : (payment.totalAmount ?? payment.amount);
  if (code === 0 && (Number(value('Amount')) !== expectedAmount || String(value('PhoneNumber')) !== payment.phone)) return {error:'mismatch'};
  return {resultCode:code,status:code === 0 ? 'SUCCESS' : code === 1032 ? 'CANCELLED' : 'FAILED',description:String(callback.ResultDesc || '').slice(0,160)};
}

export const canTransitionPayment = (status, callbackProcessedAt) => status === 'PENDING' && !callbackProcessedAt;

// Daraja callbacks have no documented request signature. Match both provider references
// and the original amount/phone before applying a one-time atomic state transition.
