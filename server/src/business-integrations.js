// CHATIFY BUSINESS INTEGRATIONS
// Provider adapters stay disabled until an operator supplies valid credentials and verifies
// the provider contract. Never treat a mock response or a queued request as a real transaction.
import {createHash, createHmac, timingSafeEqual, randomUUID} from 'node:crypto';
import {isIP} from 'node:net';

export const SUPPORTED_TAX_MODES = Object.freeze(['exclusive', 'inclusive', 'none']);
export const SUPPORTED_CURRENCIES = Object.freeze(['KES','USD','EUR','GBP','TZS','UGX','RWF','NGN','ZAR','GHS','AED','INR','CAD','AUD']);

export function calculateInternationalTotals(lines = [], config = {}) {
  if (!Array.isArray(lines) || !lines.length || lines.length > 100) throw new Error('A document must contain between 1 and 100 line items');
  const currency = String(config.currency || 'KES').toUpperCase();
  if (!SUPPORTED_CURRENCIES.includes(currency)) throw new Error('Unsupported currency; configure an approved currency before invoicing');
  const mode = config.mode || 'exclusive';
  if (!SUPPORTED_TAX_MODES.includes(mode)) throw new Error('Tax mode must be exclusive, inclusive or none');
  const rate = mode === 'none' ? 0 : Number(config.rate ?? 0);
  if (!Number.isFinite(rate) || rate < 0 || rate > 100) throw new Error('Tax rate must be between 0 and 100 percent');
  const precision = ['JPY','KRW','BIF','CLP','DJF','GNF','KMF','MGA','PYG','RWF','UGX','VND','VUV','XAF','XOF','XPF'].includes(currency) ? 0 : ['BHD','JOD','KWD','OMR','TND'].includes(currency) ? 3 : 2;
  const round = n => Number((n + Number.EPSILON).toFixed(precision));
  const normalized = lines.map(line => {
    const description = typeof line.name === 'string' ? line.name.trim().slice(0,160) : '';
    const quantity = Number(line.quantity);
    const unitPrice = Number(line.unitPrice);
    const discount = Number(line.discount || 0);
    if (!description || !Number.isFinite(quantity) || quantity <= 0 || quantity > 1_000_000 ||
        !Number.isFinite(unitPrice) || unitPrice < 0 || !Number.isFinite(discount) || discount < 0 || discount > 100) {
      throw new Error('Each line requires a description, positive quantity, valid price and discount from 0 to 100 percent');
    }
    const gross = round(quantity * unitPrice);
    const net = round(gross * (1 - discount / 100));
    return {name: description, quantity, unitPrice: round(unitPrice), discount, lineTotal: net};
  });
  const lineSubtotal = round(normalized.reduce((sum,line) => sum + line.lineTotal,0));
  const tax = mode === 'inclusive' ? round(lineSubtotal - lineSubtotal / (1 + rate / 100)) : round(lineSubtotal * rate / 100);
  const total = mode === 'inclusive' ? lineSubtotal : round(lineSubtotal + tax);
  return {currency, taxMode:mode, taxRate:rate, subtotal: mode === 'inclusive' ? round(lineSubtotal-tax) : lineSubtotal, tax, total, items:normalized};
}

// Conservative deterministic extraction. Candidates are suggestions and are never saved or sent
// automatically, so business users can review context before turning it into a task or CRM note.
export function extractBusinessMemoryCandidates(source = '') {
  const text = String(source).trim().slice(0,5000);
  if (!text) return [];
  const candidates = [];
  const add = (type,title,description,confidence) => candidates.push({id:createHash('sha256').update(type+'|'+title+'|'+description).digest('hex').slice(0,16),type,title:title.slice(0,120),description:description.slice(0,500),confidence});
  const amount = text.match(/(?:KSh|KES|USD|\$|€|£)\s?\d[\d,]*(?:\.\d{1,2})?/i);
  if (amount && /paid|pay|payment|invoice|deposit|balance|cost|price|owe/i.test(text)) add('PAYMENT','Possible payment detail',amount[0]+' — '+text,0.68);
  if (/\b(call|follow up|follow-up|remind|send|deliver|prepare|submit|meet|book|schedule|finish|complete)\b/i.test(text)) add('TASK','Possible business follow-up',text,0.62);
  if (/\b(?:tomorrow|today|next week|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday|\d{4}-\d{2}-\d{2})\b/i.test(text)) add('EVENT','Possible date or commitment',text,0.55);
  if (/\b(?:customer|client|supplier|order|invoice|quotation|quote|stock|shipment|delivery|refund)\b/i.test(text)) add('NOTE','Business context',text,0.5);
  return candidates.slice(0,6);
}

export function createIdempotencyKey(value) {
  const key = typeof value === 'string' ? value.trim() : '';
  if (key.length < 8 || key.length > 160 || !/^[a-zA-Z0-9._:-]+$/.test(key)) throw new Error('Idempotency key must be 8–160 safe characters');
  return key;
}

export function detectOfflineConflict(currentUpdatedAt, baseUpdatedAt) {
  if (!baseUpdatedAt) return {conflict:true,reason:'base_version_required'};
  const base = new Date(baseUpdatedAt).getTime();
  const current = new Date(currentUpdatedAt).getTime();
  if (!Number.isFinite(base) || !Number.isFinite(current)) return {conflict:true,reason:'invalid_version'};
  return base === current ? {conflict:false} : {conflict:true,reason:'record_changed_on_server'};
}

export function createMessagingProviders(env = process.env, transport = globalThis.fetch) {
  const request = async (url, options) => {
    if (typeof transport !== 'function') throw new Error('HTTP transport unavailable');
    const response = await transport(url, {...options, signal:AbortSignal.timeout(15000)});
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw Object.assign(new Error('Messaging provider rejected the request'),{status:response.status,providerCode:String(body.error?.code || body.code || '').slice(0,80)});
    return body;
  };
  return {
    async sendWhatsApp({to,text}) {
      const token = env.WHATSAPP_ACCESS_TOKEN?.trim();
      const phoneId = env.WHATSAPP_PHONE_NUMBER_ID?.trim();
      if (!token || !phoneId) throw new Error('WhatsApp Cloud API is not configured');
      const phone = String(to || '').replace(/\D/g,'');
      const message = String(text || '').trim().slice(0,4000);
      if (phone.length < 8 || phone.length > 15 || !message) throw new Error('Valid destination phone and message are required');
      const result = await request('https://graph.facebook.com/v21.0/'+encodeURIComponent(phoneId)+'/messages',{
        method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},
        body:JSON.stringify({messaging_product:'whatsapp',recipient_type:'individual',to:phone,type:'text',text:{preview_url:false,body:message}})
      });
      return {provider:'whatsapp-cloud',messageId:result.messages?.[0]?.id || null,accepted:Boolean(result.messages?.[0]?.id)};
    },
    async sendSms({to,text}) {
      const sid=env.TWILIO_ACCOUNT_SID?.trim(), token=env.TWILIO_AUTH_TOKEN?.trim(), from=env.TWILIO_SMS_FROM?.trim();
      if(!sid||!token||!from) throw new Error('SMS provider is not configured');
      let phone=String(to||'').trim(), message=String(text||'').trim().slice(0,1500);
      if(/^254[17]\\d{8}$/.test(phone))phone='+'+phone;
      if(/^0[17]\\d{8}$/.test(phone))phone='+254'+phone.slice(1);
      if(!/^\\+[1-9]\\d{7,14}$/.test(phone)||!message) throw new Error('SMS destination must be a valid E.164 phone number and message cannot be empty');
      const body=new URLSearchParams({To:phone,From:from,Body:message});
      const result=await request('https://api.twilio.com/2010-04-01/Accounts/'+encodeURIComponent(sid)+'/Messages.json',{
        method:'POST',headers:{Authorization:'Basic '+Buffer.from(sid+':'+token).toString('base64'),'Content-Type':'application/x-www-form-urlencoded'},body
      });
      return {provider:'twilio-sms',messageId:result.sid || null,accepted:Boolean(result.sid),status:result.status || 'accepted'};
    }
  };
}

// Uses an explicitly configured OpenAI-compatible provider. No key is required for local app
// use; missing configuration returns a clear disabled error rather than pretending to translate.
export function createLanguageProvider(env = process.env, transport = globalThis.fetch) {
  const base=(env.AI_API_BASE_URL || 'https://api.openai.com/v1').replace(/\/+$/,'');
  const key=env.AI_API_KEY?.trim();
  const textModel=env.AI_TEXT_MODEL?.trim() || 'gpt-4o-mini';
  const audioModel=env.AI_AUDIO_MODEL?.trim() || 'whisper-1';
  const request=async(path,options)=>{
    if(!key) throw new Error('AI language services are not configured');
    const response=await transport(base+path,{...options,headers:{Authorization:'Bearer '+key,...options.headers},signal:AbortSignal.timeout(60000)});
    const data=await response.json().catch(()=>({}));
    if(!response.ok) throw Object.assign(new Error('AI provider request failed'),{status:response.status});
    return data;
  };
  return {
    async translateText({text,targetLanguage,sourceLanguage}) {
      const input=String(text||'').trim(), target=String(targetLanguage||'').trim().slice(0,60);
      if(!input||input.length>10000||!target) throw new Error('Text up to 10000 characters and target language are required');
      const data=await request('/chat/completions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model:textModel,temperature:0,messages:[{role:'system',content:'Translate the user text faithfully into '+target+(sourceLanguage?' from '+String(sourceLanguage).slice(0,60):'')+'. Preserve names, numbers, prices, URLs and formatting. Return only the translation.'},{role:'user',content:input}]})});
      const translated=data.choices?.[0]?.message?.content;
      if(typeof translated!=='string'||!translated.trim()) throw new Error('Translation provider returned no text');
      return {translated:translated.trim(),targetLanguage:target,provider:'openai-compatible'};
    },
    async transcribeAndTranslate({audioBase64,mimeType,targetLanguage}) {
      const encoded=String(audioBase64||'');
      if(!encoded||encoded.length>15_000_000||!/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) throw new Error('Audio is missing, malformed or exceeds the 11 MB encoded limit');
      const bytes=Buffer.from(encoded,'base64');
      if(!bytes.length||bytes.length>11_000_000) throw new Error('Audio must be 11 MB or smaller');
      const mime=/^(audio\/(mpeg|mp4|wav|webm|ogg|x-m4a))$/.test(String(mimeType||''))?mimeType:'audio/webm';
      const form=new FormData();
      form.append('file',new Blob([bytes],{type:mime}),'voice-message.'+({ 'audio/mpeg':'mp3','audio/mp4':'m4a','audio/wav':'wav','audio/webm':'webm','audio/ogg':'ogg','audio/x-m4a':'m4a'}[mime]||'webm'));
      form.append('model',audioModel);
      const transcription=await request('/audio/transcriptions',{method:'POST',body:form});
      if(typeof transcription.text!=='string'||!transcription.text.trim()) throw new Error('Speech provider returned no transcription');
      const translated=await this.translateText({text:transcription.text,targetLanguage});
      return {transcription:transcription.text.trim(),...translated};
    }
  };
}

// eTIMS adapters vary by approved integration route. This adapter only posts the normalized
// payload to an explicitly configured authorized gateway; it never marks a submission compliant
// merely because an HTTP request succeeded.
export function createEtimsProvider(env = process.env, transport = globalThis.fetch) {
  return {
    get configured() { return Boolean(env.ETIMS_SUBMISSION_URL?.trim() && env.ETIMS_API_TOKEN?.trim() && env.ETIMS_TAXPAYER_PIN?.trim()); },
    async submitInvoice(invoice) {
      if(!this.configured) throw new Error('KRA eTIMS is not configured; set the approved gateway URL, API token and taxpayer PIN');
      const url=new URL(env.ETIMS_SUBMISSION_URL);
      const host=url.hostname.toLowerCase().replace(/^\\[|\\]$/g,'');
      const reserved=['localhost','local','internal','test','example','invalid','lan','home'];
      if(url.protocol!=='https:'||url.username||url.password||isIP(host)||!host.includes('.')||reserved.some(suffix=>host===suffix||host.endsWith('.'+suffix))) throw new Error('eTIMS gateway must be a public HTTPS hostname');
      const payload={schemaVersion:1,clientReference:String(invoice.number),taxpayerPin:env.ETIMS_TAXPAYER_PIN,invoice:{currency:invoice.currency,issueDate:invoice.issueDate,customer:invoice.customer,lines:invoice.items,subtotal:invoice.subtotal,taxRate:invoice.taxRate,tax:invoice.tax,total:invoice.total}};
      const response=await transport(url.toString(),{method:'POST',headers:{Authorization:'Bearer '+env.ETIMS_API_TOKEN,'Content-Type':'application/json','Idempotency-Key':String(invoice.idempotencyKey || invoice.number)},body:JSON.stringify(payload),signal:AbortSignal.timeout(20000)});
      const data=await response.json().catch(()=>({}));
      if(!response.ok) throw Object.assign(new Error('Configured eTIMS gateway rejected invoice submission'),{status:response.status});
      if(!data.controlUnitInvoiceNumber && !data.invoiceNumber && !data.receiptNumber) return {accepted:false,status:'pending_review',providerResponse:{code:String(data.code||'').slice(0,80)},notice:'Gateway accepted HTTP request but returned no recognized eTIMS invoice identifier; verify status with the approved provider.'};
      return {accepted:true,status:'submitted_pending_verification',controlUnitInvoiceNumber:String(data.controlUnitInvoiceNumber||data.invoiceNumber||data.receiptNumber).slice(0,120),providerResponse:{status:String(data.status||'').slice(0,80)}};
    }
  };
}

export const newIntegrationRequestId = () => randomUUID();


// Stripe Checkout adapter for international card/wallet payments. It returns a hosted checkout URL;
// invoice settlement is applied only after a signed checkout.session.completed webhook is verified.
export function createStripeProvider(env = process.env, transport = globalThis.fetch) {
  const secret = env.STRIPE_SECRET_KEY?.trim();
  const webhookSecret = env.STRIPE_WEBHOOK_SECRET?.trim();
  const mode = (env.STRIPE_ENV || (env.NODE_ENV === 'production' ? 'production' : 'test')).trim();
  if (!['test','production'].includes(mode)) throw new Error('STRIPE_ENV must be test or production');
  if (secret && ((mode === 'production' && !secret.startsWith('sk_live_')) || (mode === 'test' && !secret.startsWith('sk_test_')))) throw new Error('Stripe secret key does not match STRIPE_ENV');
  const request = async (path, body, idempotencyKey) => {
    if (!secret) throw new Error('Stripe is not configured');
    const response = await transport('https://api.stripe.com/v1'+path,{
      method:'POST',
      headers:{Authorization:'Bearer '+secret,'Content-Type':'application/x-www-form-urlencoded',...(idempotencyKey?{'Idempotency-Key':idempotencyKey}:{})},
      body,
      signal:AbortSignal.timeout(20000),
    });
    const data=await response.json().catch(()=>({}));
    if(!response.ok) throw Object.assign(new Error('Stripe rejected the checkout request'),{status:response.status,providerCode:String(data.error?.code||'').slice(0,80)});
    return data;
  };
  return {
    get configured(){return Boolean(secret&&webhookSecret&&((mode==='production'&&secret.startsWith('sk_live_'))||(mode==='test'&&secret.startsWith('sk_test_'))));},
    async createCheckoutSession({paymentId,organizationId,documentId,number,amount,currency,successUrl,cancelUrl,customerEmail}) {
      if(!secret)throw new Error('Stripe is not configured');
      const value=Number(amount), code=String(currency||'').toLowerCase();
      if(!Number.isFinite(value)||value<=0||!/^([a-z]{3})$/.test(code))throw new Error('A positive amount and ISO currency code are required');
      const zeroDecimal=new Set(['bif','clp','djf','gnf','jpy','kmf','krw','mga','pyg','rwf','ugx','vnd','vuv','xaf','xof','xpf']);
      const threeDecimal=new Set(['bhd','jod','kwd','omr','tnd']);
      const precision=zeroDecimal.has(code)?0:threeDecimal.has(code)?3:2;
      const unitAmount=Math.round(value*Math.pow(10,precision));
      if(!Number.isSafeInteger(unitAmount)||unitAmount<1)throw new Error('Amount is outside the supported payment range');
      const safeUrl=(value,label)=>{let url;try{url=new URL(value);}catch{throw new Error(label+' must be an absolute HTTPS URL');}if(url.protocol!=='https:'||url.username||url.password)throw new Error(label+' must be an HTTPS URL');return url.toString();};
      const success=safeUrl(successUrl,'Success URL'), cancel=safeUrl(cancelUrl,'Cancel URL');
      const form=new URLSearchParams({
        mode:'payment',success_url:success,cancel_url:cancel,client_reference_id:String(paymentId),
        'line_items[0][price_data][currency]':code,
        'line_items[0][price_data][unit_amount]':String(unitAmount),
        'line_items[0][price_data][product_data][name]':('Chatify invoice '+String(number)).slice(0,250),
        'line_items[0][quantity]':'1',
        'metadata[paymentId]':String(paymentId),
        'metadata[organizationId]':String(organizationId),
        'metadata[documentId]':String(documentId),
      });
      if(customerEmail&&/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(customerEmail)))form.set('customer_email',String(customerEmail).slice(0,200));
      const session=await request('/checkout/sessions',form,String(paymentId));
      if(!session.id||!session.url)throw new Error('Stripe did not return a hosted checkout URL');
      return {checkoutId:String(session.id),checkoutUrl:String(session.url),currency:code,amount:value,unitAmount};
    },
    verifyWebhook(rawBody, signature, now = Date.now()) {
      if(!webhookSecret)throw new Error('Stripe webhook is not configured');
      if(!Buffer.isBuffer(rawBody)||typeof signature!=='string')throw new Error('Stripe webhook signature is missing');
      const parts=signature.split(',').map(part=>part.split('='));
      const timestamp=Number(parts.find(part=>part[0]==='t')?.[1]);
      const candidates=parts.filter(part=>part[0]==='v1').map(part=>part[1]).filter(Boolean);
      if(!Number.isSafeInteger(timestamp)||Math.abs(Math.floor(now/1000)-timestamp)>300||!candidates.length)throw new Error('Stripe webhook signature is expired or malformed');
      const expected=createHmac('sha256',webhookSecret).update(String(timestamp)+'.').update(rawBody).digest();
      const valid=candidates.some(candidate=>{if(!/^[a-f0-9]{64}$/i.test(candidate))return false;const supplied=Buffer.from(candidate,'hex');return supplied.length===expected.length&&timingSafeEqual(supplied,expected);});
      if(!valid)throw new Error('Stripe webhook signature verification failed');
      const event=JSON.parse(rawBody.toString('utf8'));
      if (event.livemode !== (mode === 'production')) throw new Error('Stripe event mode does not match configured environment');
      return event;
    }
  };
}


// PayPal Orders v2 adapter. A verified ORDER.APPROVED webhook is captured server-side; an
// approval redirect alone never settles an invoice.
export function createPayPalProvider(env = process.env, transport = globalThis.fetch) {
  const clientId=env.PAYPAL_CLIENT_ID?.trim(), clientSecret=env.PAYPAL_CLIENT_SECRET?.trim(), webhookId=env.PAYPAL_WEBHOOK_ID?.trim();
  const mode=(env.PAYPAL_ENV||'sandbox').trim();
  if(!['sandbox','production'].includes(mode))throw new Error('PAYPAL_ENV must be sandbox or production');
  const host=mode==='production'?'https://api-m.paypal.com':'https://api-m.sandbox.paypal.com';
  let tokenValue, tokenExpiresAt=0;
  const token=async()=>{
    if(!clientId||!clientSecret)throw new Error('PayPal is not configured');
    if(tokenValue&&Date.now()<tokenExpiresAt)return tokenValue;
    const response=await transport(host+'/v1/oauth2/token',{method:'POST',headers:{Authorization:'Basic '+Buffer.from(clientId+':'+clientSecret).toString('base64'),'Content-Type':'application/x-www-form-urlencoded'},body:'grant_type=client_credentials',signal:AbortSignal.timeout(15000)});
    const data=await response.json().catch(()=>({}));
    if(!response.ok||!data.access_token)throw new Error('PayPal authentication failed');
    tokenValue=data.access_token;tokenExpiresAt=Date.now()+Math.max(0,Number(data.expires_in||0)-60)*1000;return tokenValue;
  };
  const request=async(path,body,requestId)=>{
    const access=await token();
    const response=await transport(host+path,{method:'POST',headers:{Authorization:'Bearer '+access,'Content-Type':'application/json',...(requestId?{'PayPal-Request-Id':String(requestId)}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(20000)});
    const data=await response.json().catch(()=>({}));
    if(!response.ok)throw Object.assign(new Error('PayPal rejected the checkout request'),{status:response.status});
    return data;
  };
  return {
    get configured(){return Boolean(clientId&&clientSecret&&webhookId);},
    async createOrder({paymentId,number,amount,currency,successUrl,cancelUrl}){
      if(!clientId||!clientSecret)throw new Error('PayPal is not configured');
      const value=Number(amount), code=String(currency||'').toUpperCase();
      if(!Number.isFinite(value)||value<=0||!/^[A-Z]{3}$/.test(code))throw new Error('A positive amount and ISO currency code are required');
      const formatted=value.toFixed(['JPY','KRW','CLP','VND'].includes(code)?0:2);
      const safeUrl=(input,label)=>{let url;try{url=new URL(input);}catch{throw new Error(label+' must be an absolute HTTPS URL');}if(url.protocol!=='https:'||url.username||url.password)throw new Error(label+' must be an HTTPS URL');return url.toString();};
      const order=await request('/v2/checkout/orders',{intent:'CAPTURE',purchase_units:[{reference_id:String(paymentId),custom_id:String(paymentId),invoice_id:String(number).slice(0,127),description:('Chatify invoice '+String(number)).slice(0,127),amount:{currency_code:code,value:formatted}}],application_context:{return_url:safeUrl(successUrl,'Success URL'),cancel_url:safeUrl(cancelUrl,'Cancel URL'),user_action:'PAY_NOW'}},paymentId);
      const approval=Array.isArray(order.links)?order.links.find(link=>link.rel==='approve')?.href:null;
      if(!order.id||!approval)throw new Error('PayPal did not return an approval URL');
      return {checkoutId:String(order.id),checkoutUrl:String(approval),amount:Number(formatted),currency:code,amountMinorUnits:Math.round(Number(formatted)*(['JPY','KRW','CLP','VND'].includes(code)?1:100))};
    },
    async captureOrder(orderId,paymentId){
      if(!orderId||!paymentId)throw new Error('PayPal order and payment identifiers are required');
      return request('/v2/checkout/orders/'+encodeURIComponent(orderId)+'/capture',{},'capture-'+paymentId);
    },
    async verifyWebhook(headers,event){
      if(!webhookId||!clientId||!clientSecret)throw new Error('PayPal webhook verification is not configured');
      const result=await request('/v1/notifications/verify-webhook-signature',{
        auth_algo:headers['paypal-auth-algo'],cert_url:headers['paypal-cert-url'],
        transmission_id:headers['paypal-transmission-id'],transmission_sig:headers['paypal-transmission-sig'],
        transmission_time:headers['paypal-transmission-time'],webhook_id:webhookId,webhook_event:event
      });
      if(result.verification_status!=='SUCCESS')throw new Error('PayPal webhook signature verification failed');
      return true;
    }
  };
}
