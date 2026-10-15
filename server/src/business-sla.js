// Tenant-scoped support SLA calculations and a secret-protected escalation job.
const DEFAULT_RESPONSE_MINUTES=Object.freeze({urgent:30,high:120,normal:480,low:1440});
const ACTIVE_CASE_STATUSES=['open','waiting_customer','waiting_team'];
export function normalizeSlaTargets(value={}) {
  const targets={...DEFAULT_RESPONSE_MINUTES};
  for(const key of Object.keys(targets)) {
    if(value[key]!==undefined) {
      const minutes=Number(value[key]);
      if(!Number.isSafeInteger(minutes)||minutes<5||minutes>43200) throw new Error('SLA targets must be whole minutes from 5 to 43200');
      targets[key]=minutes;
    }
  }
  return targets;
}
export function calculateCaseSla(item,targets=DEFAULT_RESPONSE_MINUTES,now=new Date()) {
  const priority=Object.hasOwn(targets,item.priority)?item.priority:'normal';
  const createdAt=new Date(item.createdAt||now);
  const deadline=item.dueAt?new Date(item.dueAt):new Date(createdAt.getTime()+targets[priority]*60000);
  const active=ACTIVE_CASE_STATUSES.includes(item.status);
  const remainingMs=deadline.getTime()-now.getTime();
  return {deadline,active,breached:active&&remainingMs<0,remainingMinutes:Math.ceil(remainingMs/60000),priority};
}
export function nextEscalationPriority(priority,overdueMinutes,targetMinutes) {
  if(!Number.isFinite(overdueMinutes)||overdueMinutes<=0) return priority;
  if(overdueMinutes>=targetMinutes*2) return 'urgent';
  if(priority==='low'||priority==='normal') return 'high';
  return priority;
}
export function registerBusinessSlaRoutes({app,auth,mongoose}) {
  const Organization=mongoose.models.BusinessOrganization;
  const BusinessCase=mongoose.models.BusinessCase;
  if(!Organization||!BusinessCase) throw new Error('Register business routes before SLA routes');
  const base='/api/business/organizations/:orgId/support/sla';
  const getOrg=async(req,res)=>{
    if(!mongoose.isValidObjectId(req.params.orgId)) {res.status(404).json({error:'Business workspace not found'});return null;}
    const org=await Organization.findOne({_id:req.params.orgId,$or:[{ownerId:req.user._id},{'members.userId':req.user._id}]});
    if(!org) {res.status(404).json({error:'Business workspace not found'});return null;}
    const member=(org.members||[]).find(m=>String(m.userId)===String(req.user._id));
    req.slaRole=String(org.ownerId)===String(req.user._id)?'owner':(member?.role||'viewer');
    return org;
  };
  app.get(base,auth,async(req,res)=>{
    const org=await getOrg(req,res);if(!org)return;
    const targets=normalizeSlaTargets(org.settings?.serviceTargets?.responseMinutes||{});
    const cases=await BusinessCase.find({organizationId:org._id}).sort({createdAt:-1}).limit(200).lean();
    const now=new Date();
    return res.json({targets,generatedAt:now.toISOString(),cases:cases.map(item=>({
      id:String(item._id),title:item.title,status:item.status,priority:item.priority,
      sla:calculateCaseSla(item,targets,now),
    }))});
  });
  // External scheduler calls this endpoint with a deployment secret; never expose it publicly.
  app.post('/api/business/support/sla/escalate',async(req,res)=>{
    const secret=process.env.CHATIFY_SLA_CRON_SECRET;
    const supplied=String(req.get('x-chatify-sla-secret')||'');
    if(!secret||supplied.length!==secret.length||supplied!==secret) return res.status(401).json({error:'Unauthorized'});
    const cases=await BusinessCase.find({status:{$in:ACTIVE_CASE_STATUSES}}).sort({createdAt:1}).limit(1000);
    const orgCache=new Map();const escalated=[];const now=new Date();
    for(const item of cases) {
      const key=String(item.organizationId);
      if(!orgCache.has(key)) orgCache.set(key,await Organization.findById(item.organizationId).select('settings').lean());
      const org=orgCache.get(key);
      const targets=normalizeSlaTargets(org?.settings?.serviceTargets?.responseMinutes||{});
      const sla=calculateCaseSla(item,targets,now);
      if(!sla.breached)continue;
      const overdueMinutes=Math.abs(sla.remainingMinutes);
      const priority=nextEscalationPriority(item.priority,overdueMinutes,targets[sla.priority]);
      if(priority===item.priority)continue;
      item.priority=priority;
      item.updates.push({body:'Automatic SLA escalation: priority raised to '+priority+'.',createdAt:now});
      await item.save();
      escalated.push({caseId:String(item._id),organizationId:key,priority});
    }
    return res.json({scanned:cases.length,escalated:escalated.length,items:escalated,generatedAt:now.toISOString()});
  });
}
