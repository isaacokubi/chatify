import {rejectLockedWorkspace} from './workspace-billing-access.js';
// Versioned read-only API with revocable, tenant-scoped credentials.
import {createHash,randomBytes} from 'node:crypto';
const ALLOWED_SCOPES=['catalog:read'];
export function normalizeApiKeyRequest(input={}) {
 const label=typeof input.label==='string'?input.label.trim().slice(0,80):'';
 const scopes=Array.isArray(input.scopes)?[...new Set(input.scopes)]:['catalog:read'];
 if(!label)throw new Error('API key label is required');
 if(!scopes.length||scopes.some(scope=>!ALLOWED_SCOPES.includes(scope)))throw new Error('Unsupported API key scope');
 const expiresInDays=input.expiresInDays==null?90:Number(input.expiresInDays);
 if(!Number.isSafeInteger(expiresInDays)||expiresInDays<1||expiresInDays>365)throw new Error('API key expiry must be 1 to 365 days');
 return {label,scopes,expiresInDays};
}
export function hashApiKey(token) {return createHash('sha256').update(String(token||'')).digest('hex');}
export function createApiKeyToken() {return 'cfy_'+randomBytes(32).toString('base64url');}
export function hasApiScope(key,scope,now=new Date()) {
 return Boolean(key&&!key.revokedAt&&(!key.expiresAt||new Date(key.expiresAt)>now)&&(key.scopes||[]).includes(scope));
}
export function registerBusinessPublicApiRoutes({app,auth,mongoose}) {
 const Organization=mongoose.models.BusinessOrganization;
 const CatalogItem=mongoose.models.BusinessCatalogItem;
 if(!Organization||!CatalogItem)throw new Error('Register business routes before public API');
 const O=mongoose.Schema.Types.ObjectId;
 const ApiKey=mongoose.models.BusinessApiKey||mongoose.model('BusinessApiKey',new mongoose.Schema({
  organizationId:{type:O,required:true,index:true},label:{type:String,required:true,maxlength:80},
  prefix:{type:String,required:true},keyHash:{type:String,required:true,unique:true,select:false},
  scopes:{type:[String],enum:ALLOWED_SCOPES,required:true},createdBy:{type:O,required:true},
  expiresAt:Date,revokedAt:Date,lastUsedAt:Date,
 },{timestamps:true}));
 const base='/api/business/organizations/:orgId/integrations/api-keys';
 const getOrg=async(req,res)=>{
  if(!mongoose.isValidObjectId(req.params.orgId)){res.status(404).json({error:'Business workspace not found'});return null;}
  const org=await Organization.findOne({_id:req.params.orgId,$or:[{ownerId:req.user._id},{'members.userId':req.user._id}]});
  if(!org){res.status(404).json({error:'Business workspace not found'});return null;}
  if(await rejectLockedWorkspace(mongoose,org,res))return null;
  const member=(org.members||[]).find(m=>String(m.userId)===String(req.user._id));
  const role=String(org.ownerId)===String(req.user._id)?'owner':(member?.role||'viewer');
  if(!['owner','admin','manager'].includes(role)){res.status(403).json({error:'Manager permission required'});return null;}
  return org;
 };
 app.get(base,auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  const keys=await ApiKey.find({organizationId:org._id}).select('label prefix scopes createdBy expiresAt revokedAt lastUsedAt createdAt').sort({createdAt:-1}).lean();
  return res.json({keys});
 });
 app.post(base,auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  let input;try{input=normalizeApiKeyRequest(req.body);}catch(error){return res.status(400).json({error:error.message});}
  const token=createApiKeyToken();
  const key=await ApiKey.create({organizationId:org._id,label:input.label,scopes:input.scopes,createdBy:req.user._id,
   prefix:token.slice(0,12),keyHash:hashApiKey(token),expiresAt:new Date(Date.now()+input.expiresInDays*86400000)});
  return res.status(201).json({key:{id:String(key._id),label:key.label,prefix:key.prefix,scopes:key.scopes,expiresAt:key.expiresAt},token,warning:'Copy this token now. It cannot be retrieved again.'});
 });
 app.delete(base+'/:keyId',auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  if(!mongoose.isValidObjectId(req.params.keyId))return res.status(404).json({error:'API key not found'});
  const key=await ApiKey.findOneAndUpdate({_id:req.params.keyId,organizationId:org._id,revokedAt:{$exists:false}},{$set:{revokedAt:new Date()}},{new:true}).select('label prefix revokedAt');
  if(!key)return res.status(404).json({error:'Active API key not found'});
  return res.json({key,message:'API key revoked'});
 });
 // Public v1 endpoint returns only active, public catalogue fields and never exposes owner/customer data.
 app.get('/api/v1/storefronts/:slug/catalog',async(req,res)=>{
  const authorization=String(req.get('authorization')||'');
  const token=authorization.startsWith('Bearer ')?authorization.slice(7).trim():'';
  if(!/^cfy_[A-Za-z0-9_-]{35,60}$/.test(token))return res.status(401).json({error:'Valid Chatify API key required'});
  const key=await ApiKey.findOne({keyHash:hashApiKey(token)}).select('+keyHash');
  if(!hasApiScope(key,'catalog:read'))return res.status(401).json({error:'API key is invalid, expired or revoked'});
  const slug=String(req.params.slug||'').toLowerCase();
  const org=await Organization.findOne({_id:key.organizationId,slug,'settings.storefrontPublished':{$ne:false}}).select('name slug currency country billing');
  if(!org)return res.status(404).json({error:'Published storefront not found'});
  if(await rejectLockedWorkspace(mongoose,org,res))return;
  const page=Math.max(1,Math.min(100000,Number.parseInt(req.query.page,10)||1));
  const pageSize=Math.max(1,Math.min(50,Number.parseInt(req.query.pageSize,10)||20));
  const filter={organizationId:org._id,active:true};
  const [items,total]=await Promise.all([
   CatalogItem.find(filter).select('name description price currency images category type').sort({name:1}).skip((page-1)*pageSize).limit(pageSize).lean(),
   CatalogItem.countDocuments(filter),
  ]);
  await ApiKey.updateOne({_id:key._id,revokedAt:{$exists:false}},{$set:{lastUsedAt:new Date()}});
  res.set('Cache-Control','private, max-age=30');
  return res.json({version:'v1',business:{name:org.name,slug:org.slug,currency:org.currency,country:org.country},items,pagination:{page,pageSize,total,totalPages:Math.ceil(total/pageSize)}});
 });
}
