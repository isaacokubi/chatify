// Customer self-service portal API. Orders and requests are scoped to the signed-in buyer.
const REQUEST_TYPES=['cancellation','return','support','delivery_question'];
const REQUEST_STATUSES=['pending','approved','rejected','resolved'];
const clean=(value,max=2000)=>typeof value==='string'?value.trim().slice(0,max):'';
export function normalizePortalRequest(input={}) {
 const type=clean(input.type,40);const reason=clean(input.reason,2000);
 if(!REQUEST_TYPES.includes(type))throw new Error('Unsupported customer request type');
 if(reason.length<5)throw new Error('Explain the request in at least five characters');
 return {type,reason};
}
export function registerBusinessCustomerPortalRoutes({app,auth,mongoose}) {
 const Organization=mongoose.models.BusinessOrganization;
 const Document=mongoose.models.BusinessDocument;
 if(!Organization||!Document)throw new Error('Register business routes before customer portal routes');
 const O=mongoose.Schema.Types.ObjectId;
 const PortalRequest=mongoose.models.BusinessPortalRequest||mongoose.model('BusinessPortalRequest',new mongoose.Schema({
  organizationId:{type:O,required:true,index:true},customerUserId:{type:O,required:true,index:true},
  documentId:{type:O,required:true,index:true},type:{type:String,enum:REQUEST_TYPES,required:true},
  reason:{type:String,required:true,maxlength:2000},status:{type:String,enum:REQUEST_STATUSES,default:'pending',index:true},
  response:{type:String,maxlength:2000},decidedBy:O,decidedAt:Date,
 },{timestamps:true}));
 PortalRequest.schema.index({customerUserId:1,documentId:1,type:1,status:1});
 app.get('/api/customer/portal/orders',auth,async(req,res)=>{
  const docs=await Document.find({createdBy:req.user._id,type:'order'}).sort({createdAt:-1}).limit(100)
   .select('organizationId number status items subtotal tax total paidAmount currency dueDate createdAt updatedAt').lean();
  const orgIds=[...new Set(docs.map(d=>String(d.organizationId)))];
  const orgs=await Organization.find({_id:{$in:orgIds}}).select('name slug').lean();
  const byId=new Map(orgs.map(o=>[String(o._id),o]));
  return res.json({orders:docs.map(d=>({id:String(d._id),number:d.number,status:d.status,items:d.items,
   subtotal:d.subtotal,tax:d.tax,total:d.total,paidAmount:d.paidAmount,currency:d.currency,dueDate:d.dueDate,
   createdAt:d.createdAt,updatedAt:d.updatedAt,business:byId.get(String(d.organizationId))||{name:'Business',slug:''}}))});
 });
 app.get('/api/customer/portal/requests',auth,async(req,res)=>{
  const requests=await PortalRequest.find({customerUserId:req.user._id}).sort({createdAt:-1}).limit(100).lean();
  return res.json({requests});
 });
 app.post('/api/customer/portal/requests',auth,async(req,res)=>{
  if(!mongoose.isValidObjectId(req.body?.orderId))return res.status(400).json({error:'A valid order ID is required'});
  let input;try{input=normalizePortalRequest(req.body);}catch(error){return res.status(400).json({error:error.message});}
  const order=await Document.findOne({_id:req.body.orderId,type:'order',createdBy:req.user._id});
  if(!order)return res.status(404).json({error:'Order not found'});
  if(input.type==='cancellation'&&['fulfilled','cancelled','rejected'].includes(order.status))return res.status(409).json({error:'This order can no longer be cancelled through the portal'});
  if(input.type==='return'&&order.status!=='fulfilled')return res.status(409).json({error:'Returns can only be requested for fulfilled orders'});
  const request=await PortalRequest.create({organizationId:order.organizationId,customerUserId:req.user._id,documentId:order._id,...input});
  return res.status(201).json({request,notice:'Request submitted for business review. This does not itself cancel an order or issue a refund.'});
 });
 const base='/api/business/organizations/:orgId/portal/requests';
 const getOrg=async(req,res)=>{
  if(!mongoose.isValidObjectId(req.params.orgId)){res.status(404).json({error:'Business workspace not found'});return null;}
  const org=await Organization.findOne({_id:req.params.orgId,$or:[{ownerId:req.user._id},{'members.userId':req.user._id}]});
  if(!org){res.status(404).json({error:'Business workspace not found'});return null;}
  const member=(org.members||[]).find(m=>String(m.userId)===String(req.user._id));
  const role=String(org.ownerId)===String(req.user._id)?'owner':(member?.role||'viewer');
  if(!['owner','admin','manager','support','finance','fulfilment'].includes(role)){res.status(403).json({error:'Business role cannot manage customer requests'});return null;}
  return org;
 };
 app.get(base,auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  const filter={organizationId:org._id};
  if(REQUEST_STATUSES.includes(req.query.status))filter.status=req.query.status;
  const requests=await PortalRequest.find(filter).sort({createdAt:-1}).limit(200).lean();
  return res.json({requests});
 });
 app.post(base+'/:requestId/decision',auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  if(!mongoose.isValidObjectId(req.params.requestId))return res.status(404).json({error:'Customer request not found'});
  const decision=clean(req.body?.decision,20);
  if(!['approved','rejected','resolved'].includes(decision))return res.status(400).json({error:'Choose approved, rejected or resolved'});
  const request=await PortalRequest.findOne({_id:req.params.requestId,organizationId:org._id});
  if(!request)return res.status(404).json({error:'Customer request not found'});
  if(request.status!=='pending'&&decision!=='resolved')return res.status(409).json({error:'Request has already been reviewed'});
  request.status=decision;request.response=clean(req.body?.response,2000);request.decidedBy=req.user._id;request.decidedAt=new Date();
  await request.save();
  return res.json({request,notice:'This decision records the request outcome; payment refunds and provider actions must be processed separately.'});
 });
}
