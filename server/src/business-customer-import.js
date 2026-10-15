// Tenant-safe CSV customer import. Preview and commit use the same parser and validation rules.
import {planQuotaStatus} from './business-entitlements.js';
const MAX_ROWS=500,MAX_BYTES=1_000_000;
export function parseCsv(source) {
 if(typeof source!=='string'||Buffer.byteLength(source,'utf8')>MAX_BYTES)throw new Error('CSV must be text no larger than 1 MB');
 const rows=[];let row=[],cell='',quoted=false;
 for(let i=0;i<source.length;i++){
  const ch=source[i];
  if(quoted){
   if(ch==='"'&&source[i+1]==='"'){cell+='"';i++;}
   else if(ch==='"')quoted=false;
   else cell+=ch;
  } else if(ch==='"'){
   if(cell.length)throw new Error('Unexpected quote in CSV field');
   quoted=true;
  } else if(ch===','){row.push(cell.trim());cell='';}
  else if(ch==='\n'||ch==='\r'){
   if(ch==='\r'&&source[i+1]==='\n')i++;
   row.push(cell.trim());cell='';
   if(row.some(value=>value!==''))rows.push(row);
   row=[];
  } else cell+=ch;
  if(rows.length>MAX_ROWS+1)throw new Error('CSV may contain at most 500 customer rows');
 }
 if(quoted)throw new Error('CSV contains an unclosed quoted field');
 row.push(cell.trim());if(row.some(value=>value!==''))rows.push(row);
 if(rows.length<2)throw new Error('CSV must contain a header and at least one customer row');
 if(rows.length>MAX_ROWS+1)throw new Error('CSV may contain at most 500 customer rows');
 const headers=rows.shift().map(value=>value.toLowerCase().replace(/\s+/g,'_'));
 if(new Set(headers).size!==headers.length)throw new Error('CSV headers must be unique');
 if(!headers.includes('name'))throw new Error('CSV requires a name header');
 const allowed=new Set(['name','email','phone','company','notes','tags']);
 if(headers.some(header=>!allowed.has(header)))throw new Error('Unsupported CSV header. Use name,email,phone,company,notes,tags');
 return rows.map((values,index)=>{
  const record={};headers.forEach((header,i)=>record[header]=values[i]||'');
  const rowNumber=index+2;
  if(values.length>headers.length)return {rowNumber,record,error:'Too many columns'};
  const name=String(record.name||'').trim().slice(0,160);
  const email=String(record.email||'').trim().toLowerCase().slice(0,200);
  const phone=String(record.phone||'').trim().slice(0,40);
  if(!name)return {rowNumber,record,error:'Name is required'};
  if(email&&!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))return {rowNumber,record,error:'Invalid email address'};
  if(!email&&!phone)return {rowNumber,record,error:'Provide an email address or phone number'};
  return {rowNumber,record:{name,email,phone,company:String(record.company||'').trim().slice(0,160),notes:String(record.notes||'').trim().slice(0,4000),tags:String(record.tags||'').split(';').map(tag=>tag.trim().slice(0,40)).filter(Boolean).slice(0,30)},error:null};
 });
}
export function registerBusinessCustomerImportRoutes({app,auth,mongoose}) {
 const Organization=mongoose.models.BusinessOrganization;
 const Customer=mongoose.models.BusinessCustomer;
 if(!Organization||!Customer)throw new Error('Register business routes before customer import');
 const base='/api/business/organizations/:orgId/import/customers';
 const getOrg=async(req,res)=>{
  if(!mongoose.isValidObjectId(req.params.orgId)){res.status(404).json({error:'Business workspace not found'});return null;}
  const org=await Organization.findOne({_id:req.params.orgId,$or:[{ownerId:req.user._id},{'members.userId':req.user._id}]});
  if(!org){res.status(404).json({error:'Business workspace not found'});return null;}
  const member=(org.members||[]).find(m=>String(m.userId)===String(req.user._id));
  const role=String(org.ownerId)===String(req.user._id)?'owner':(member?.role||'viewer');
  if(!['owner','admin','manager'].includes(role)){res.status(403).json({error:'Manager permission required for customer imports'});return null;}
  return org;
 };
 const prepare=async(org,csv)=>{
  const rows=parseCsv(csv);
  const identifiers=rows.filter(row=>!row.error).flatMap(row=>[row.record.email?{email:row.record.email}:null,row.record.phone?{phone:row.record.phone}:null].filter(Boolean));
  const existing=identifiers.length?await Customer.find({organizationId:org._id,$or:identifiers}).select('email phone').lean():[];
  const emails=new Set(existing.map(item=>String(item.email||'').toLowerCase()).filter(Boolean));
  const phones=new Set(existing.map(item=>String(item.phone||'')).filter(Boolean));
  const seenEmails=new Set(),seenPhones=new Set();
  for(const row of rows){
   if(row.error)continue;
   const {email,phone}=row.record;
   if((email&&emails.has(email))||(phone&&phones.has(phone))){row.error='Customer already exists in this workspace';continue;}
   if((email&&seenEmails.has(email))||(phone&&seenPhones.has(phone))){row.error='Duplicate email or phone in this CSV';continue;}
   if(email)seenEmails.add(email);if(phone)seenPhones.add(phone);
  }
  return rows;
 };
 app.post(base+'/preview',auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  try{
   const rows=await prepare(org,req.body?.csv);
   return res.json({total:rows.length,valid:rows.filter(row=>!row.error).length,invalid:rows.filter(row=>row.error).length,rows});
  }catch(error){return res.status(400).json({error:error.message});}
 });
 app.post(base,auth,async(req,res)=>{
  const org=await getOrg(req,res);if(!org)return;
  let rows;try{rows=await prepare(org,req.body?.csv);}catch(error){return res.status(400).json({error:error.message});}
  const invalid=rows.filter(row=>row.error);
  if(invalid.length&&!req.body?.allowPartial)return res.status(422).json({error:'Import has invalid or duplicate rows; preview and correct the CSV or explicitly allow partial import',total:rows.length,invalid});
  const current=await Customer.countDocuments({organizationId:org._id});
  const valid=rows.filter(row=>!row.error);
  for(let i=0;i<valid.length;i++)if(!planQuotaStatus(org.plan,'customers',current+i).allowed)return res.status(409).json({error:'Customer plan limit reached; no rows were imported',limitReached:true,allowedRows:i});
  if(valid.length)await Customer.insertMany(valid.map(row=>({organizationId:org._id,...row.record,source:'import'})),{ordered:true});
  return res.status(201).json({imported:valid.length,skipped:invalid.length,invalid});
 });
}
