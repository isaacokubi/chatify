// Verified-purchase reviews: only a buyer with a paid/fulfilled order can submit a review.
const text=(value,max)=>typeof value==='string'?value.trim().slice(0,max):'';
export function normalizeReview(input={}) {
 const rating=Number(input.rating);const title=text(input.title,120);const comment=text(input.comment,2000);
 if(!Number.isInteger(rating)||rating<1||rating>5)throw new Error('Rating must be a whole number from 1 to 5');
 if(comment.length<5)throw new Error('Review must contain at least five characters');
 return {rating,title,comment};
}
export function registerBusinessReviewRoutes({app,auth,mongoose}) {
 const Organization=mongoose.models.BusinessOrganization;
 const Document=mongoose.models.BusinessDocument;
 if(!Organization||!Document)throw new Error('Register business routes before review routes');
 const O=mongoose.Schema.Types.ObjectId;
 const Review=mongoose.models.BusinessReview||mongoose.model('BusinessReview',new mongoose.Schema({
  organizationId:{type:O,required:true,index:true},orderId:{type:O,required:true,unique:true,index:true},
  customerUserId:{type:O,required:true,index:true},rating:{type:Number,min:1,max:5,required:true},
  title:{type:String,maxlength:120,default:''},comment:{type:String,required:true,maxlength:2000},
  status:{type:String,enum:['pending','approved','rejected'],default:'pending',index:true},
  moderatedBy:O,moderatedAt:Date,
 },{timestamps:true}));
 const publicSlug=async slug=>Organization.findOne({slug:String(slug||'').toLowerCase(),'settings.storefrontPublished':{$ne:false}}).select('_id name slug');
 app.get('/api/storefront/:slug/reviews',async(req,res)=>{
  const org=await publicSlug(req.params.slug);if(!org)return res.status(404).json({error:'Storefront not found'});
  const reviews=await Review.find({organizationId:org._id,status:'approved'}).sort({createdAt:-1}).limit(100).select('rating title comment createdAt').lean();
  const count=reviews.length;const average=count?Math.round(reviews.reduce((sum,r)=>sum+r.rating,0)/count*100)/100:0;
  return res.json({business:{name:org.name,slug:org.slug},averageRating:average,reviewCount:count,reviews});
 });
 app.post('/api/storefront/:slug/reviews',auth,async(req,res)=>{
  const org=await publicSlug(req.params.slug);if(!org)return res.status(404).json({error:'Storefront not found'});
  let input;try{input=normalizeReview(req.body);}catch(error){return res.status(400).json({error:error.message});}
  const orderId=String(req.body?.orderId||'');
  if(!mongoose.isValidObjectId(orderId))return res.status(400).json({error:'A valid order ID is required'});
  const order=await Document.findOne({_id:orderId,organizationId:org._id,type:'order',createdBy:req.user._id,status:{$in:['paid','fulfilled']}});
  if(!order)return res.status(403).json({error:'A paid or fulfilled order from this store is required to review'});
  try {
   const review=await Review.create({organizationId:org._id,orderId:order._id,customerUserId:req.user._id,...input});
   return res.status(201).json({review,notice:'Review submitted for moderation and will appear publicly after approval.'});
  } catch(error) {
   if(error?.code===11000)return res.status(409).json({error:'This order already has a review'});
   throw error;
  }
 });
 const base='/api/business/organizations/:orgId/reviews';
 const manager=async(req,res)=>{
  if(!mongoose.isValidObjectId(req.params.orgId))return null;
  const org=await Organization.findOne({_id:req.params.orgId,$or:[{ownerId:req.user._id},{'members.userId':req.user._id}]});
  if(!org)return null;
  const member=(org.members||[]).find(m=>String(m.userId)===String(req.user._id));
  const role=String(org.ownerId)===String(req.user._id)?'owner':(member?.role||'viewer');
  return ['owner','admin','manager'].includes(role)?org:null;
 };
 app.get(base,auth,async(req,res)=>{
  const org=await manager(req,res);if(!org)return res.status(404).json({error:'Review management not found'});
  const filter={organizationId:org._id};if(['pending','approved','rejected'].includes(req.query.status))filter.status=req.query.status;
  return res.json({reviews:await Review.find(filter).sort({createdAt:-1}).limit(200).lean()});
 });
 app.post(base+'/:reviewId/moderate',auth,async(req,res)=>{
  const org=await manager(req,res);if(!org)return res.status(404).json({error:'Review management not found'});
  if(!mongoose.isValidObjectId(req.params.reviewId))return res.status(404).json({error:'Review not found'});
  const status=text(req.body?.status,20);if(!['approved','rejected'].includes(status))return res.status(400).json({error:'Choose approved or rejected'});
  const review=await Review.findOne({_id:req.params.reviewId,organizationId:org._id});
  if(!review)return res.status(404).json({error:'Review not found'});
  review.status=status;review.moderatedBy=req.user._id;review.moderatedAt=new Date();await review.save();
  return res.json({review});
 });
}
