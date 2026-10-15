// Subscription lifecycle API for Chatify Business.
// Upgrade requests never grant paid access: only a signed billing event can change the plan.
import {createHmac, timingSafeEqual} from 'node:crypto';
export const SUBSCRIPTION_PLANS = Object.freeze({
  free: Object.freeze({label:'Free', recurring:false}),
  business_pro: Object.freeze({label:'Business Pro', recurring:true}),
  teams: Object.freeze({label:'Teams', recurring:true}),
  enterprise: Object.freeze({label:'Enterprise', recurring:true}),
});
const validObjectId = value => /^[a-f\d]{24}$/i.test(String(value || ''));
export function normalizeSubscriptionRequest(input={}) {
  const plan=typeof input.plan==='string'?input.plan.trim().toLowerCase():'';
  if(!Object.hasOwn(SUBSCRIPTION_PLANS,plan)||plan==='free') throw new Error('Choose a supported paid plan');
  return {plan};
}
export function normalizeSubscriptionEvent(input={}) {
  const eventId=typeof input.eventId==='string'?input.eventId.trim():'';
  const organizationId=typeof input.organizationId==='string'?input.organizationId.trim():'';
  const eventType=typeof input.eventType==='string'?input.eventType.trim():'';
  if(!/^[A-Za-z0-9._:-]{8,180}$/.test(eventId)) throw new Error('Invalid billing event ID');
  if(!validObjectId(organizationId)) throw new Error('Invalid organization ID');
  if(!['subscription.activated','subscription.past_due','subscription.canceled','subscription.expired'].includes(eventType)) throw new Error('Unsupported billing event type');
  const plan=input.plan==null?undefined:String(input.plan).trim().toLowerCase();
  if(plan!==undefined&&!Object.hasOwn(SUBSCRIPTION_PLANS,plan)) throw new Error('Unsupported subscription plan');
  if(eventType==='subscription.activated'&&(!plan||plan==='free')) throw new Error('Activation requires a paid plan');
  const currentPeriodEnd=input.currentPeriodEnd==null?undefined:new Date(input.currentPeriodEnd);
  if(currentPeriodEnd&&!Number.isFinite(currentPeriodEnd.getTime())) throw new Error('Invalid subscription period end');
  return {eventId,organizationId,eventType,...(plan?{plan}:{}),...(currentPeriodEnd?{currentPeriodEnd}:{})};
}
export function verifyBillingSignature(rawBody,signature,secret) {
  if(!Buffer.isBuffer(rawBody)||!rawBody.length||typeof signature!=='string'||!secret) return false;
  const supplied=signature.replace(/^sha256=/i,'').trim();
  if(!/^[a-f\d]{64}$/i.test(supplied)) return false;
  const expected=createHmac('sha256',secret).update(rawBody).digest();
  const actual=Buffer.from(supplied,'hex');
  return actual.length===expected.length&&timingSafeEqual(actual,expected);
}
export function subscriptionStateForEvent(event,now=new Date()) {
  if(event.eventType==='subscription.activated') {
    if(event.currentPeriodEnd&&event.currentPeriodEnd<=now) throw new Error('Activation period must end in the future');
    return {plan:event.plan,subscription:{status:'active',plan:event.plan,currentPeriodEnd:event.currentPeriodEnd,updatedAt:now}};
  }
  if(event.eventType==='subscription.past_due') return {subscription:{status:'past_due',plan:event.plan, currentPeriodEnd:event.currentPeriodEnd,updatedAt:now}};
  if(event.eventType==='subscription.canceled'||event.eventType==='subscription.expired') {
    const status=event.eventType==='subscription.canceled'?'canceled':'expired';
    return {plan:'free',subscription:{status,plan:'free',updatedAt:now}};
  }
  throw new Error('Unsupported billing event type');
}
export function registerBusinessSubscriptionRoutes({app,auth,mongoose}) {
  const Organization=mongoose.models.BusinessOrganization;
  if(!Organization) throw new Error('Register business routes before subscription routes');
  const O=mongoose.Schema.Types.ObjectId;
  const BillingEvent=mongoose.models.BusinessBillingEvent||mongoose.model('BusinessBillingEvent',new mongoose.Schema({
    providerEventId:{type:String,required:true,unique:true},organizationId:{type:O,required:true,index:true},
    eventType:{type:String,required:true},processedAt:Date,
  },{timestamps:true}));
  const base='/api/business/organizations/:orgId/subscription';
  const owned=async(req,res)=>{
    if(!mongoose.isValidObjectId(req.params.orgId)) {res.status(404).json({error:'Business workspace not found'});return null;}
    const org=await Organization.findOne({_id:req.params.orgId,ownerId:req.user._id});
    if(!org) {res.status(404).json({error:'Business workspace not found'});return null;}
    return org;
  };
  app.get('/api/business/subscription-plans',(_req,res)=>res.json({
    plans:Object.entries(SUBSCRIPTION_PLANS).map(([id,plan])=>({id,...plan})),
    billingConfigured:Boolean(process.env.CHATIFY_BILLING_WEBHOOK_SECRET),
  }));
  app.get(base,auth,async(req,res)=>{
    const org=await owned(req,res); if(!org)return;
    return res.json({plan:org.plan||'free',subscription:org.settings?.subscription||{status:'active',plan:'free'},billingConfigured:Boolean(process.env.CHATIFY_BILLING_WEBHOOK_SECRET)});
  });
  app.post(base+'/request',auth,async(req,res)=>{
    const org=await owned(req,res); if(!org)return;
    let requested; try{requested=normalizeSubscriptionRequest(req.body);}catch(error){return res.status(400).json({error:error.message});}
    if(!process.env.CHATIFY_BILLING_WEBHOOK_SECRET) return res.status(503).json({error:'Subscription billing is not configured; no plan change was made'});
    org.settings=org.settings||{};
    org.settings.subscription={...(org.settings.subscription||{}),status:'incomplete',requestedPlan:requested.plan,requestedAt:new Date()};
    await org.save();
    return res.status(202).json({message:'Upgrade request recorded; paid access remains disabled until the billing provider confirms payment.',plan:org.plan||'free',subscription:org.settings.subscription});
  });
  // Trusted billing adapter signs exact JSON bytes with HMAC-SHA256 in x-chatify-billing-signature.
  app.post('/api/business/billing/webhook',async(req,res)=>{
    const secret=process.env.CHATIFY_BILLING_WEBHOOK_SECRET;
    if(!secret||!verifyBillingSignature(req.rawBody,req.get('x-chatify-billing-signature'),secret)) return res.status(401).json({error:'Invalid billing signature'});
    let event; try{event=normalizeSubscriptionEvent(req.body);}catch(error){return res.status(400).json({error:error.message});}
    const org=await Organization.findById(event.organizationId);
    if(!org)return res.status(404).json({error:'Business workspace not found'});
    let record;
    try {
      record=await BillingEvent.findOneAndUpdate({providerEventId:event.eventId},
        {$setOnInsert:{providerEventId:event.eventId,organizationId:org._id,eventType:event.eventType}},
        {upsert:true,new:true,setDefaultsOnInsert:true});
    } catch(error) {
      if(error?.code===11000)return res.json({received:true,duplicate:true});
      throw error;
    }
    if(String(record.organizationId)!==String(org._id)||record.eventType!==event.eventType)return res.status(409).json({error:'Billing event ID conflicts with a previously received event'});
    if(record.processedAt)return res.json({received:true,duplicate:true});
    const state=subscriptionStateForEvent(event);
    org.plan=state.plan||org.plan||'free';
    org.settings=org.settings||{};
    org.settings.subscription={...(org.settings.subscription||{}),...state.subscription};
    if(state.subscription.status==='active') delete org.settings.subscription.requestedPlan;
    org.markModified('settings');
    await org.save();
    await BillingEvent.updateOne({_id:record._id,processedAt:{$exists:false}},{$set:{processedAt:new Date()}});
    return res.json({received:true,applied:true,status:state.subscription.status});
  });
}
