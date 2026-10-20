// CHATIFY API SERVER — READING GUIDE
// This is the Express/Socket.IO entrypoint. It configures security middleware and providers,
// defines MongoDB models, authenticates REST requests, enforces membership/ownership rules,
// and emits real-time events. Supporting modules (auth.js, payments.js and provider modules)
// hold reusable logic. Keep secrets in environment variables; never trust client-supplied
// user IDs, payment outcomes, or conversation membership without checking them on the server.

import 'dotenv/config';
import {resolveMpesaProvider,normalizeMpesaPhone,validPaymentAmount,newPaymentId,PAYMENT_STATUSES,resolveCallbackOutcome,calculatePaymentTotal,canAccessPayment,canRetryPayment,canTransitionPayment,canCancelPayment} from './payments.js';
import {createAuthMiddleware,createAdminMiddleware} from './auth.js';
import {isValidEncryptedPayload} from './e2ee.js';
import {randomBytes} from 'node:crypto';
import http from 'node:http'; import express from 'express'; import cors from 'cors'; import helmet from 'helmet'; import rateLimit from 'express-rate-limit'; import bcrypt from 'bcryptjs'; import jwt from 'jsonwebtoken'; import mongoose from 'mongoose'; import {Server} from 'socket.io'; import {createEmailProvider,createStorageProvider,createNotificationProvider,isSupportedImageData,isAllowedMessageMediaUrl} from './providers.js'; import {resolveClientOrigins,corsOriginCallback,resolveNodeEnv,requireProductionMongoUri} from './config.js'; import {createResetToken,hashResetToken,resetExpiry,messageExpiry,expiresWhenRepliedTo,validPassword,normalizeLoginCredentials,createShutdownHandler} from './lifecycle.js';
import {registerBusinessRoutes} from './business.js';
import {MAX_NOTIFICATION_ATTEMPTS,notificationRetryDelayMs,notificationExpiryDate} from './notification-queue.js';
import {registerBusinessPosRoutes} from './business-pos.js';
import {registerBusinessEnterpriseRoutes} from './business-enterprise.js';
import {registerBusinessSearchRoutes} from './business-search.js';
import {registerBusinessMarketplaceRoutes} from './business-marketplace.js';
import {registerBusinessStatementRoutes} from './business-statements.js';
import {registerBusinessSubscriptionRoutes} from './business-subscriptions.js';
import {registerBusinessSlaRoutes} from './business-sla.js';
import {registerBusinessCustomerPortalRoutes} from './business-customer-portal.js';
import {registerBusinessReviewRoutes} from './business-reviews.js';
import {registerBusinessCustomerImportRoutes} from './business-customer-import.js';
import {registerBusinessPublicApiRoutes} from './business-public-api.js';
import {registerPublicStatusRoute} from './service-status.js';
import {registerSchoolRoutes} from './school.js';
import {createPlatformFeeCollector} from './platform-fee-collection.js';
import {registerWorkspaceBillingRoutes,applyWorkspaceBillingPayment} from './workspace-billing.js';
import {unhideConversationForUser} from './conversation-visibility.js';
// Read runtime configuration first so production-only security rules can be applied consistently.
const nodeEnv=resolveNodeEnv(process.env.NODE_ENV);
const configuredJwt=process.env.JWT_SECRET?.trim();
if(nodeEnv==='production'&&(!configuredJwt||configuredJwt.length<32))throw new Error('Production requires JWT_SECRET with at least 32 characters');
const production=nodeEnv==='production';
const env={port:+(process.env.PORT||5000),mongo:production?requireProductionMongoUri(process.env.MONGODB_URI):(process.env.MONGODB_URI||''),jwt:configuredJwt||randomBytes(32).toString('hex'),jwtExpiresIn:process.env.JWT_EXPIRES_IN?.trim()||'7d',origin:process.env.CLIENT_ORIGIN||process.env.CLIENT_ORIGINS||process.env.CLIENT_URL||'*'};
const origins=resolveClientOrigins(env.origin,production);
if(production&&origins.origins.size===0)console.warn('CLIENT_ORIGIN is not configured; browser origins are denied.');
const corsOrigin=corsOriginCallback(origins);
const emailProvider=createEmailProvider({smtpUrl:process.env.SMTP_URL,from:process.env.SMTP_FROM,production});
const storageProvider=createStorageProvider({cloudinaryUrl:process.env.CLOUDINARY_URL,production:process.env.NODE_ENV==='production'});
const notificationProvider=createNotificationProvider({fcmProjectId:process.env.FCM_PROJECT_ID,serviceAccountJson:process.env.FIREBASE_SERVICE_ACCOUNT_JSON,production});
const mpesaProvider=resolveMpesaProvider(process.env);
// The platform fee collector uses separate platform-owned Daraja credentials; it never reuses a merchant or school's shortcode.
const app=express(); app.set('trust proxy', 1); app.use(helmet()); app.use(cors({origin:corsOrigin,credentials:true})); app.use(express.json({limit:'15mb',verify:(req,res,buffer)=>{if(req.originalUrl?.startsWith('/api/business/payments/stripe/webhook')||req.originalUrl?.startsWith('/api/business/billing/webhook'))req.rawBody=Buffer.from(buffer);}})); app.use(rateLimit({windowMs:900000,max:300,standardHeaders:true,legacyHeaders:false}));
const authRateLimitHandler=(_req,res)=>res.status(429).json({error:'Too many authentication attempts. Please wait before trying again.'});
const loginRateLimit=rateLimit({windowMs:15*60*1000,max:10,standardHeaders:true,legacyHeaders:false,handler:authRateLimitHandler});
const registrationRateLimit=rateLimit({windowMs:60*60*1000,max:5,standardHeaders:true,legacyHeaders:false,handler:authRateLimitHandler});
const recoveryRateLimit=rateLimit({windowMs:15*60*1000,max:5,standardHeaders:true,legacyHeaders:false,handler:authRateLimitHandler});
const verificationRateLimit=rateLimit({windowMs:15*60*1000,max:20,standardHeaders:true,legacyHeaders:false,handler:authRateLimitHandler});
// MongoDB schemas below describe the durable records used by the app.
const O=mongoose.Schema.Types.ObjectId;
const platformFeeCollector=createPlatformFeeCollector({mongoose,env:process.env});
// User accounts include password hashes, profile/privacy settings, blocked users and push-notification tokens.
const User=mongoose.model('User',new mongoose.Schema({name:{type:String,required:true,trim:true,maxlength:80},email:{type:String,unique:true,lowercase:true,trim:true,required:true},sessionVersion:{type:Number,default:0},phone:String,encryptionPublicKey:{type:String,select:true},passwordHash:{type:String,required:true},emailVerified:{type:Boolean,default:true},emailVerificationTokenHash:String,emailVerificationExpiresAt:Date,profileImage:String,status:{type:String,default:'active'},role:{type:String,enum:['user','admin'],default:'user',index:true},demoSeedKey:{type:String,select:false},lastSeen:Date,privacy:{lastSeen:{type:Boolean,default:true},readReceipts:{type:Boolean,default:true}},blockedUsers:[O],pushTokens:{type:[String],default:[]},notificationPreferences:{messages:{type:Boolean,default:true},mentions:{type:Boolean,default:true},memories:{type:Boolean,default:true}}},{timestamps:true}));
User.schema.index({name:'text',email:'text'});
// Conversations track direct/group membership, group admins, hidden state and the latest-message summary.
const Conversation=mongoose.model('Conversation',new mongoose.Schema({type:{type:String,enum:['direct','group'],default:'direct'},participants:[{type:O,ref:'User'}],hiddenFor:{type:[O],default:[]},directKey:{type:String,unique:true,sparse:true},title:String,description:String,image:String,admins:[O],lastMessage:{text:String,senderId:O,createdAt:Date}},{timestamps:true}));
Conversation.schema.index({participants:1,updatedAt:-1}); Conversation.schema.index({participants:1,updatedAt:-1,_id:-1},{name:'participant_recent_conversations_v1'});
// Messages store text/media, replies, reactions, delivery/read receipts and application-level expiry state.
const Message=mongoose.model('Message',new mongoose.Schema({conversationId:{type:O,index:true},senderId:O,text:{type:String,trim:true,maxlength:5000},encryptedPayload:{type:String,select:true},encryptionVersion:{type:Number,enum:[1]},messageType:{type:String,enum:['text','image','file'],default:'text'},mediaUrl:String,replyTo:O,reactions:[{userId:O,emoji:String}],hiddenFor:[O],deliveredTo:[O],readBy:[O],expiryType:{type:String,enum:['NONE','AFTER_READ','AFTER_TIME','AFTER_REPLY'],default:'NONE'},expiresAt:Date,expiredAt:Date,deletedAt:Date},{timestamps:true}));
Message.schema.index({conversationId:1,createdAt:-1,_id:-1},{name:'conversation_history_cursor_v1'}); Message.schema.index({expiresAt:1,expiredAt:1,conversationId:1},{name:'message_expiry_sweep_v1'});
// Memory Cards are user-owned structured notes extracted from conversation context or entered by the user.
const Memory=mongoose.model('Memory',new mongoose.Schema({userId:{type:O,index:true},conversationId:O,personId:{type:O,index:true},personName:{type:String,trim:true,maxlength:80},type:{type:String,enum:['EVENT','PAYMENT','PLACE','TASK','NOTE','OTHER']},title:String,description:String,date:Date,time:String,location:String,sourceMessageId:O,completed:{type:Boolean,default:false}},{timestamps:true}));
// Supports bounded newest-first user memory reads and cursor pagination without scanning deep offsets.
Memory.schema.index({userId:1,createdAt:-1,_id:-1},{name:'user_memory_history_cursor_v1'});
// Persist every message that has already produced a memory suggestion. This ledger is deliberately separate from Memory so deleting a saved card never makes its source message eligible again.
const MemorySuggestionSeen=mongoose.model('MemorySuggestionSeen',new mongoose.Schema({userId:{type:O,required:true},conversationId:{type:O,required:true},sourceMessageId:{type:O,required:true},status:{type:String,enum:['suggested','saved','dismissed','deleted'],default:'suggested'}},{timestamps:true}));
MemorySuggestionSeen.schema.index({userId:1,sourceMessageId:1},{unique:true});
const SavedContact=mongoose.model('SavedContact',new mongoose.Schema({userId:{type:O,required:true,index:true},contactUserId:{type:O,ref:'User',required:true,index:true},nameOverride:{type:String,trim:true,maxlength:80}},{timestamps:true}));
SavedContact.schema.index({userId:1,contactUserId:1},{unique:true});
// Durable idempotent push-notification outbox shared by API replicas.
const NotificationJob=mongoose.model('NotificationJob',new mongoose.Schema({recipientId:{type:O,required:true},messageId:{type:O,required:true},conversationId:{type:O,required:true},status:{type:String,enum:['queued','processing','done','failed'],default:'queued',index:true},availableAt:{type:Date,default:Date.now,required:true},lockedUntil:Date,attempts:{type:Number,default:0},completedAt:Date,expireAt:Date,lastError:{type:String,maxlength:180}},{timestamps:true,collection:'notificationjobs'}));
NotificationJob.schema.index({recipientId:1,messageId:1},{unique:true,name:'notification_job_dedupe_v1'});
NotificationJob.schema.index({status:1,availableAt:1,lockedUntil:1,createdAt:1},{name:'notification_jobs_claim_v1'});
NotificationJob.schema.index({expireAt:1},{expireAfterSeconds:0,name:'notification_jobs_ttl_v1',partialFilterExpression:{expireAt:{$type:'date'}}});
const PasswordReset=mongoose.model('PasswordReset',new mongoose.Schema({userId:{type:O,required:true,index:true},tokenHash:{type:String,required:true,unique:true},expiresAt:{type:Date,required:true,expires:0}},{timestamps:true}));
// Payment records track requester/payer, amount, provider references and lifecycle status.
const Payment=mongoose.model('Payment',new mongoose.Schema({paymentId:{type:String,required:true,unique:true,index:true},requesterId:{type:O,required:true,index:true},payerId:{type:O,required:true,index:true},conversationId:{type:O,index:true},amount:{type:Number,required:true,min:1,max:150000},baseAmount:{type:Number,min:1,max:150000},platformFee:{type:Number,min:0,max:750,default:0},totalAmount:{type:Number,min:1,max:150000},platformFeeRate:{type:Number,default:0},platformFeeStatus:{type:String,enum:['NOT_APPLICABLE','PENDING_PAYMENT','PENDING_SETTLEMENT','SETTLED','FAILED'],default:'NOT_APPLICABLE'},feeCollectionMode:{type:String,enum:['combined','separate'],default:'separate'},billingType:{type:String,enum:['workspace_setup','workspace_subscription']},billingWorkspaceType:{type:String,enum:['business','school']},billingWorkspaceId:{type:O,index:true},billingAppliedAt:Date,recipientPhone:{type:String},payerPhone:{type:String},phone:{type:String},businessOrganizationId:{type:O,index:true},businessDocumentId:{type:O,index:true},description:{type:String,required:true,maxlength:80},purpose:{type:String,enum:['REQUEST','SELF_STK'],default:'REQUEST'},status:{type:String,enum:PAYMENT_STATUSES,default:'PENDING',index:true},provider:{type:String,required:true},checkoutRequestId:{type:String,sparse:true,index:true},merchantRequestId:String,resultCode:Number,resultDescription:String,requestedAt:{type:Date,required:true},initiating:{type:Boolean,default:false},initiatedAt:Date,completedAt:Date,callbackProcessedAt:Date,dismissedBy:{type:[O],default:[]}},{timestamps:true}));
Payment.schema.index({checkoutRequestId:1,merchantRequestId:1},{unique:true,sparse:true});
const PlatformFeeLedger=mongoose.models.PlatformFeeLedger||mongoose.model('PlatformFeeLedger',new mongoose.Schema({paymentId:{type:String,required:true,unique:true,index:true},source:{type:String,enum:['personal_request','business_checkout','business_pos','school_fee'],required:true},businessOrganizationId:{type:O,index:true},baseAmount:{type:Number,required:true,min:1},feeAmount:{type:Number,required:true,min:1},totalAmount:{type:Number,required:true,min:1},currency:{type:String,default:'KES'},status:{type:String,enum:['PENDING_SETTLEMENT','SETTLED','REVERSED'],default:'PENDING_SETTLEMENT',index:true},providerReceipt:{type:String,default:null},confirmedAt:{type:Date,required:true}},{timestamps:true}));
async function recordPlatformFee(payment,source='personal_request',providerReceipt=null){if(!payment||!payment.platformFee||payment.platformFeeStatus==='NOT_APPLICABLE')return;await Payment.updateOne({paymentId:payment.paymentId,status:'SUCCESS'},{$set:{platformFeeStatus:'PENDING_SETTLEMENT'}});await PlatformFeeLedger.updateOne({paymentId:payment.paymentId},{$setOnInsert:{paymentId:payment.paymentId,source,businessOrganizationId:payment.businessOrganizationId||undefined,baseAmount:payment.baseAmount??payment.amount,feeAmount:payment.platformFee,totalAmount:payment.totalAmount??payment.amount,currency:'KES',status:'PENDING_SETTLEMENT',providerReceipt,confirmedAt:payment.completedAt||new Date()}},{upsert:true});}
const safe=u=>({id:String(u._id),name:u.name,email:u.email,emailVerified:u.emailVerified!==false,phone:u.phone,encryptionPublicKey:u.encryptionPublicKey,profileImage:u.profileImage,status:u.status,role:u.role||'user',lastSeen:u.lastSeen,privacy:u.privacy,notificationPreferences:u.notificationPreferences});
const visibleUser=u=>{const value=u.toObject?u.toObject():{...u};if(value.privacy?.lastSeen===false)delete value.lastSeen;return value;};
const sign=u=>jwt.sign({sub:String(u._id),sv:Number(u.sessionVersion||0)},env.jwt,{expiresIn:env.jwtExpiresIn});
// Authentication middleware verifies a bearer token and loads its user before protected handlers run.
const auth=createAuthMiddleware({verifyToken:token=>jwt.verify(token,env.jwt),findUser:id=>User.findById(id)});
import {candidate} from './memory.js';
// HTTP serves REST; Socket.IO shares this server for authenticated real-time chat events.
const server=http.createServer(app); const io=new Server(server,{cors:{origin:corsOrigin,credentials:true}});
// Immediately close all live realtime connections when an account's credentials are revoked.
const revokeUserSockets=userId=>io.in('user:'+String(userId)).disconnectSockets(true);
// Register Business routes only after auth and Socket.IO exist. Registering earlier hits
// JavaScript's temporal-dead-zone for these const bindings and prevents the API from booting.
registerBusinessRoutes({app,auth,mongoose,User,Conversation,Payment,io,mpesaProvider,platformFeeCollector});
// In-person merchant checkout routes depend on the organization model created above.
registerBusinessPosRoutes({app,auth,mongoose,mpesaProvider,platformFeeCollector});
// Register additional enterprise tools only after the core Business models and auth are available.
registerBusinessEnterpriseRoutes({app,auth,mongoose});
registerBusinessSearchRoutes({app,auth,mongoose});
// Public discovery routes expose only published business and catalogue fields.
registerBusinessMarketplaceRoutes({app,mongoose});
registerBusinessStatementRoutes({app,auth,mongoose});
registerBusinessSubscriptionRoutes({app,auth,mongoose});
registerBusinessSlaRoutes({app,auth,mongoose});
registerBusinessCustomerPortalRoutes({app,auth,mongoose});
registerBusinessReviewRoutes({app,auth,mongoose});
registerBusinessCustomerImportRoutes({app,auth,mongoose});
registerBusinessPublicApiRoutes({app,auth,mongoose});
registerPublicStatusRoute({app,mongoose});
registerSchoolRoutes({app,auth,mongoose,User,emailProvider,platformFeeCollector});
registerWorkspaceBillingRoutes({app,auth,mongoose,Payment,mpesaProvider});
io.use(async(s,n)=>{try{s.user=jwt.verify(s.handshake.auth?.token,env.jwt);const account=await User.findOne({_id:s.user.sub,status:'active'}).select('sessionVersion').lean();if(!account||Number(s.user.sv??0)!==Number(account.sessionVersion??0))throw new Error('Inactive or revoked session');n();}catch{n(new Error('Unauthorized'));}});
const onlineUsers=new Set();
const leaveUserConversation=(userId,conversationId)=>io.in('user:'+String(userId)).socketsLeave(String(conversationId));
// Fan out conversation events to every signed-in device, including sockets not subscribed to the room.
const emitConversationEvent=(conversation,event,payload)=>{const id=String(conversation._id||conversation);io.to(id).emit(event,payload);if(Array.isArray(conversation.participants)&&conversation.participants.length)io.to(conversation.participants.map(member=>'user:'+String(member?._id||member))).except(id).emit(event,payload);};
io.on('connection',async s=>{
 const userId=String(s.user.sub);
 s.join('user:'+userId);
 // Do not scan and join every historical conversation at each socket connect. Clients join
 // older conversations on demand with conversation:join after server-side membership checks.
 const activeConversations=await Conversation.find({participants:userId}).sort({updatedAt:-1,_id:-1}).limit(100).select('_id participants').lean();
 for(const c of activeConversations)s.join(String(c._id));
 const peerIds=new Set(activeConversations.flatMap(c=>c.participants.map(id=>String(id))).filter(id=>id!==userId));
 s.emit('presence:initial',{userIds:[...peerIds].filter(id=>onlineUsers.has(id))});
 const firstSocket=!onlineUsers.has(userId);
 onlineUsers.add(userId);
 if(firstSocket)for(const peerId of peerIds)io.to('user:'+peerId).emit('user:online',{userId});
 for(const c of activeConversations){s.to(String(c._id)).emit('user:online',{userId});for(const id of c.participants)if(String(id)!==userId&&onlineUsers.has(String(id)))s.emit('user:online',{userId:String(id)});}
 s.on('conversation:join',async id=>{if(typeof id!=='string'||!mongoose.isValidObjectId(id))return;const c=await Conversation.exists({_id:id,participants:userId});if(c)s.join(id);});
 for(const event of ['typing:start','typing:stop'])s.on(event,async id=>{if(typeof id!=='string'||!s.rooms.has(id))return;s.to(id).emit(event,{userId});});
 s.on('disconnect',async()=>{
   const sockets=await io.in('user:'+userId).fetchSockets();
   if(!sockets.length){
     onlineUsers.delete(userId);
     const u=await User.findByIdAndUpdate(userId,{lastSeen:new Date()});
     // Presence fan-out is bounded to recently active conversations; historical conversations
     // receive events when opened and subscribed, avoiding unbounded disconnect work.
     const conversations=await Conversation.find({participants:userId}).sort({updatedAt:-1,_id:-1}).limit(100).select('_id participants').lean();
     const peers=new Set(conversations.flatMap(c=>c.participants.map(id=>String(id))).filter(id=>id!==userId));
     for(const peerId of peers)io.to('user:'+peerId).emit('user:offline',{userId,...(u?.privacy?.lastSeen!==false?{lastSeen:u?.lastSeen}:{})});
     if(u)for(const conversation of conversations)io.to(String(conversation._id)).emit('user:offline',{userId,...(u.privacy?.lastSeen!==false?{lastSeen:u.lastSeen}:{})});
   }
 });
});
// HEALTH CHECK: reports whether MongoDB is connected so hosting platforms can detect an unhealthy API.
app.get('/health',(q,r)=>{const connected=mongoose.connection.readyState===1;r.status(connected?200:503).json({ok:connected,service:'chatify-api',database:connected?'connected':'unavailable',readyState:mongoose.connection.readyState,uptimeSeconds:Math.floor(process.uptime()),time:new Date().toISOString()});});
// Readiness is suitable for load balancers; it never exposes credentials or database details.
app.get('/ready',(q,r)=>{const connected=mongoose.connection.readyState===1;r.status(connected?200:503).json({ready:connected});});
app.post('/api/media',auth,async(q,r)=>{
  if(q.body?.data!=null&&!isSupportedImageData(q.body.data,q.body.mimeType))return r.status(400).json({error:'Choose a valid JPEG, PNG or WebP image no larger than 10 MB'});
  const {data,mimeType,url}=q.body||{};
  if(typeof url==='string'&&/^https:\/\//i.test(url)&&url.length<=2048){
    try{return r.status(201).json(await storageProvider.upload({path:url,mimetype:'image/remote'}));}
    catch{return r.status(503).json({error:'Image storage is not configured'});}
  }
  if(typeof data!=='string'||data.length>14*1024*1024||!isSupportedImageData(data,mimeType))return r.status(400).json({error:'Choose a valid JPEG, PNG or WebP image no larger than 10 MB'});
  try{r.status(201).json(await storageProvider.upload({data,mimeType}));}
  catch{return r.status(503).json({error:'Image storage is not configured'});}
});
// AUTHENTICATION ROUTES: validate registration/login data, issue JWTs and handle password recovery.
app.post('/api/auth/register',registrationRateLimit,async(q,r)=>{const {name,email,password,phone}=q.body||{};const normalizedEmail=typeof email==='string'?email.trim().toLowerCase():'';const normalizedPhone=normalizeMpesaPhone(phone);if(typeof name!=='string'||!name.trim()||name.trim().length>80||!/^\S+@\S+\.\S+$/.test(normalizedEmail)||!validPassword(password)||!normalizedPhone)return r.status(400).json({error:'Enter a name, valid email, valid Kenyan M-Pesa phone number and password of 8–72 UTF-8 bytes'});if(await User.exists({email:normalizedEmail}))return r.status(409).json({error:'Email already registered'});if(production&&!emailProvider.available)return r.status(503).json({error:'Email confirmation is not configured. Configure SMTP_URL and SMTP_FROM before accepting registrations.'});const verificationRequired=emailProvider.available;const verificationToken=verificationRequired?createResetToken():null;const u=await User.create({name:name.trim(),email:normalizedEmail,phone:normalizedPhone,passwordHash:await bcrypt.hash(password,12),emailVerified:!verificationRequired,...(verificationToken?{emailVerificationTokenHash:hashResetToken(verificationToken),emailVerificationExpiresAt:new Date(Date.now()+24*60*60*1000)}:{})});if(verificationRequired){const base=(process.env.PUBLIC_API_URL||process.env.API_URL||'https://chatify-api-c1eh.onrender.com').replace(/\/$/,'');const verificationUrl=base+'/api/auth/verify-email?token='+encodeURIComponent(verificationToken);try{await emailProvider.sendEmailVerification({email:normalizedEmail,verificationUrl,expiresAt:u.emailVerificationExpiresAt});}catch{await User.deleteOne({_id:u._id});return r.status(503).json({error:'Could not send the confirmation email. Check the mail service settings and try again.'});}return r.status(201).json({verificationRequired:true,message:'Account created. Check your email and open the confirmation link before signing in.'});}r.status(201).json({token:sign(u),user:safe(u)});});
app.get('/api/auth/verify-email',verificationRateLimit,async(q,r)=>{const token=typeof q.query.token==='string'?q.query.token:'';if(!token||token.length>200)return r.status(400).json({error:'A valid email confirmation token is required'});const user=await User.findOneAndUpdate({emailVerified:false,emailVerificationTokenHash:hashResetToken(token),emailVerificationExpiresAt:{$gt:new Date()}},{$set:{emailVerified:true},$unset:{emailVerificationTokenHash:1,emailVerificationExpiresAt:1}},{new:true});if(!user)return r.status(400).json({error:'Confirmation link is invalid or expired. Request a new registration or contact support.'});const configuredWebUrl=process.env.PUBLIC_WEB_URL?.trim()||'';let loginUrl='';try{const parsed=new URL(configuredWebUrl);if(parsed.protocol==='https:')loginUrl=parsed.toString();}catch{}const loginLink=loginUrl?'<p><a href="'+loginUrl.replace(/&/g,'&amp;').replace(/"/g,'&quot;')+'" style="display:inline-block;background:#5b4bdb;color:#fff;text-decoration:none;padding:12px 20px;border-radius:10px;font-weight:700">Open Chatify</a></p>':'';r.type('html').send('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Email confirmed · Chatify</title><body style="margin:0;background:#f5f6fb;color:#202033;font:16px system-ui,sans-serif;min-height:100vh;display:grid;place-items:center"><main style="max-width:480px;margin:24px;padding:32px;background:#fff;border:1px solid #e5e7f0;border-radius:20px;box-shadow:0 12px 40px #20203312;text-align:center"><div style="font-size:42px">✓</div><h1 style="margin:8px 0">Email confirmed</h1><p>Your Chatify account is verified. You can now sign in securely.</p>'+loginLink+'<p style="font-size:13px;color:#68687b">Chatify · Chat. Remember. Let Go.</p></main></body></html>');});
app.post('/api/auth/login',loginRateLimit,async(q,r)=>{const credentials=normalizeLoginCredentials(q.body);if(!credentials)return r.status(401).json({error:'Invalid email or password'});const u=await User.findOne({email:credentials.email});if(!u||!(await bcrypt.compare(credentials.password,u.passwordHash)))return r.status(401).json({error:'Invalid email or password'});if(u.emailVerified===false)return r.status(403).json({error:'Confirm your email address using the link we sent before signing in.'});u.lastSeen=new Date();await u.save();r.json({token:sign(u),user:safe(u)});});
app.get('/api/auth/me',auth,(q,r)=>r.json({user:safe(q.user)}));
// Register a device-generated X25519 public key. The private key never leaves the client.
app.put('/api/users/me/encryption-key',auth,async(q,r)=>{const key=q.body?.publicKey;if(typeof key!=='string'||!/^([A-Za-z0-9+/]{43}=)$/.test(key)||Buffer.from(key,'base64').length!==32)return r.status(400).json({error:'A valid 32-byte X25519 public key is required'});if(q.user.encryptionPublicKey&&q.user.encryptionPublicKey!==key)return r.status(409).json({error:'This account already has a different encryption key. Secure key transfer or recovery is required before replacing it.'});q.user.encryptionPublicKey=key;await q.user.save();r.json({publicKey:key});});
/**
 * Platform administration endpoints. Every route requires a verified server-side admin role;
 * the client cannot grant itself privileges by changing a submitted JSON field.
 */
const requireAdmin=createAdminMiddleware();
app.get('/api/admin/overview',auth,requireAdmin,async(q,r)=>{
  const since=new Date(Date.now()-24*60*60*1000);
  const optionalCount=(model,filter={})=>model?model.countDocuments(filter):Promise.resolve(0);
  const [totalUsers,activeUsers,verifiedUsers,totalConversations,totalMessages,totalMemories,totalPayments,pendingPayments,successfulPayments,failedPayments,recentUsers,recentPayments,totalBusinesses,businessCustomers,catalogItems,openCases,newUsers24h,newMessages24h,newBusinesses24h]=await Promise.all([
    User.countDocuments({}),User.countDocuments({status:'active'}),User.countDocuments({emailVerified:true}),
    Conversation.countDocuments({}),Message.countDocuments({}),Memory.countDocuments({}),Payment.countDocuments({}),
    Payment.countDocuments({status:'PENDING'}),Payment.countDocuments({status:'SUCCESS'}),Payment.countDocuments({status:'FAILED'}),
    User.find({}).sort({createdAt:-1}).limit(8).select('name email role status emailVerified createdAt lastSeen'),
    Payment.find({}).sort({createdAt:-1}).limit(8).select('paymentId amount baseAmount platformFee totalAmount platformFeeStatus status provider description createdAt requesterId payerId').lean(),
    optionalCount(mongoose.models.BusinessOrganization),
    optionalCount(mongoose.models.BusinessCustomer),
    optionalCount(mongoose.models.BusinessCatalogItem,{active:true}),
    optionalCount(mongoose.models.BusinessCase,{status:{$nin:['resolved','closed']}}),
    User.countDocuments({createdAt:{$gte:since}}),
    Message.countDocuments({createdAt:{$gte:since}}),
    optionalCount(mongoose.models.BusinessOrganization,{createdAt:{$gte:since}}),
  ]);
  const [totalSchools, totalStudents, totalAttendanceRecords, totalAssessments, totalSchoolFees] = await Promise.all([
    optionalCount(mongoose.models.SchoolWorkspace),
    optionalCount(mongoose.models.SchoolStudent, { active: true }),
    optionalCount(mongoose.models.SchoolAttendance),
    optionalCount(mongoose.models.SchoolAssessment),
    optionalCount(mongoose.models.SchoolFeePayment),
  ]);
  const revenue=await Payment.aggregate([{$match:{status:'SUCCESS'}},{$group:{_id:null,total:{$sum:{$ifNull:['$totalAmount','$amount']}},count:{$sum:1}}}]);
  const feeSummary=await PlatformFeeLedger.aggregate([{$match:{status:'PENDING_SETTLEMENT'}},{$group:{_id:null,totalFee:{$sum:'$feeAmount'},count:{$sum:1}}}]);
  r.json({stats:{totalUsers,activeUsers,verifiedUsers,totalConversations,totalMessages,totalMemories,totalPayments,pendingPayments,successfulPayments,failedPayments,successfulPaymentAmount:revenue[0]?.total||0,pendingPlatformFeeAmount:feeSummary[0]?.totalFee||0,pendingPlatformFeeCount:feeSummary[0]?.count||0,totalBusinesses,businessCustomers,catalogItems,openCases,newUsers24h,newMessages24h,newBusinesses24h,totalSchools,totalStudents,totalAttendanceRecords,totalAssessments,totalSchoolFees},recentUsers,recentPayments,generatedAt:new Date().toISOString()});
});
app.get('/api/admin/users',auth,requireAdmin,async(q,r)=>{
  const page=Math.max(1,Math.min(10000,Number.parseInt(q.query.page,10)||1));
  const limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||25));
  // Restrict search syntax so user input cannot inject regular-expression operators.
  const term=typeof q.query.q==='string'?q.query.q.trim().slice(0,80):'';
  const safeTerm=term.replace(/[^a-zA-Z0-9 @._+-]/g,'');
  const filter=safeTerm?{$or:[{name:{$regex:safeTerm,$options:'i'}},{email:{$regex:safeTerm,$options:'i'}}]}:{};
  const [users,total]=await Promise.all([User.find(filter).sort({createdAt:-1}).skip((page-1)*limit).limit(limit).select('name email role status emailVerified createdAt lastSeen'),User.countDocuments(filter)]);
  r.json({users,total,page,limit});
});
app.patch('/api/admin/users/:id/status',auth,requireAdmin,async(q,r)=>{
  if(!mongoose.isValidObjectId(q.params.id))return r.status(400).json({error:'Invalid user ID'});
  if(String(q.params.id)===String(q.user._id))return r.status(400).json({error:'You cannot change your own account status'});
  const status=q.body?.status;
  if(!['active','suspended'].includes(status))return r.status(400).json({error:'Status must be active or suspended'});
  const target=await User.findById(q.params.id);
  if(!target)return r.status(404).json({error:'User not found'});
  if(target.role==='admin'&&status==='suspended'){
    const admins=await User.countDocuments({role:'admin',status:'active'});
    if(admins<=1)return r.status(409).json({error:'Cannot suspend the last active administrator'});
  }
  target.status=status;await target.save();
  r.json({user:safe(target)});
});
app.get('/api/admin/payments',auth,requireAdmin,async(q,r)=>{
  const page=Math.max(1,Math.min(10000,Number.parseInt(q.query.page,10)||1));
  const limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||25));
  const status=typeof q.query.status==='string'?q.query.status:'';
  const filter=PAYMENT_STATUSES.includes(status)?{status}:{};
  const [payments,total]=await Promise.all([Payment.find(filter).sort({createdAt:-1}).skip((page-1)*limit).limit(limit).select('paymentId amount baseAmount platformFee totalAmount platformFeeStatus status provider description createdAt requesterId payerId conversationId'),Payment.countDocuments(filter)]);
  r.json({payments,total,page,limit});
});

// Store the platform fee destination separately from individual user and merchant accounts.
const PlatformFeeSettings=mongoose.models.PlatformFeeSettings||mongoose.model('PlatformFeeSettings',new mongoose.Schema({
  key:{type:String,unique:true,default:'global'},
  enabled:{type:Boolean,default:true},
  feeRate:{type:Number,min:0,max:5,default:0.5},
  walletType:{type:String,enum:['mpesa_phone','mpesa_paybill','mpesa_till'],default:'mpesa_phone'},
  walletPhone:{type:String,default:''},
  paybillNumber:{type:String,default:''},
  tillNumber:{type:String,default:''},
  accountReference:{type:String,default:'CHATIFY-FEE'},
  updatedBy:{type:O,default:null},
},{timestamps:true}));
// Platform-owned STK callback: only the collector's exact request IDs, expected fee amount, payer phone and receipt can settle a fee.
app.post('/api/payments/platform-fee/callback',async(q,r)=>{try{const result=await platformFeeCollector.processCallback(q.body?.Body?.stkCallback);if(result.error==='malformed')return r.status(400).json({error:'Malformed platform fee callback'});return r.json({ok:true,...result});}catch(error){console.error('Platform fee callback processing failed');return r.status(500).json({error:'Could not process platform fee callback'});}});
app.get('/api/admin/platform-fee-settings',auth,requireAdmin,async(q,r)=>{
  const settings=await PlatformFeeSettings.findOne({key:'global'}).lean();
  // A saved destination is not proof that Daraja can automatically collect platform fees.
  // Live collection requires platform-owned Daraja credentials and a Paybill/Till shortcode.
  const configured=settings||{enabled:true,feeRate:0.5,walletType:'mpesa_phone',walletPhone:'',paybillNumber:'',tillNumber:'',accountReference:'CHATIFY-FEE'};
  const walletConfigured=configured.walletType==='mpesa_paybill'?Boolean(configured.paybillNumber):configured.walletType==='mpesa_till'?Boolean(configured.tillNumber):Boolean(configured.walletPhone);
  const configuredWalletNumber=configured.walletType==='mpesa_paybill'?String(configured.paybillNumber||''):configured.walletType==='mpesa_till'?String(configured.tillNumber||''):'';
  const walletMatchesShortcode=Boolean(configuredWalletNumber&&process.env.PLATFORM_FEE_MPESA_SHORTCODE&&configuredWalletNumber===String(process.env.PLATFORM_FEE_MPESA_SHORTCODE).trim());
  const darajaConfigured=Boolean(process.env.PLATFORM_FEE_MPESA_CONSUMER_KEY&&process.env.PLATFORM_FEE_MPESA_CONSUMER_SECRET&&process.env.PLATFORM_FEE_MPESA_PASSKEY&&process.env.PLATFORM_FEE_MPESA_CALLBACK_URL&&process.env.PLATFORM_FEE_MPESA_ENV&&process.env.PLATFORM_FEE_MPESA_SHORTCODE);
  r.json({settings:configured,collection:{walletConfigured,darajaConfigured,automaticCollectionReady:configured.enabled&&walletConfigured&&darajaConfigured&&walletMatchesShortcode&&(configured.walletType==='mpesa_paybill'||configured.walletType==='mpesa_till'),walletMatchesShortcode,status:configured.enabled&&walletConfigured&&darajaConfigured&&walletMatchesShortcode&&(configured.walletType==='mpesa_paybill'||configured.walletType==='mpesa_till')?'ready_for_test':'setup_required',requiredEnvironment:['PLATFORM_FEE_MPESA_ENV','PLATFORM_FEE_MPESA_CONSUMER_KEY','PLATFORM_FEE_MPESA_CONSUMER_SECRET','PLATFORM_FEE_MPESA_SHORTCODE','PLATFORM_FEE_MPESA_PASSKEY','PLATFORM_FEE_MPESA_CALLBACK_URL']}});
});
// Read-only, paginated reconciliation endpoint for administrators. It never exposes payer phones.
app.get('/api/admin/platform-fees',auth,requireAdmin,async(q,r)=>{
  const page=Math.max(1,Math.min(10000,Number.parseInt(q.query.page,10)||1));
  const limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||25));
  const status=['PENDING_SETTLEMENT','SETTLED','REVERSED'].includes(q.query.status)?q.query.status:null;
  const filter=status?{status}:{};
  const [fees,total,summary]=await Promise.all([
    PlatformFeeLedger.find(filter).sort({createdAt:-1}).skip((page-1)*limit).limit(limit).select('paymentId source businessOrganizationId baseAmount feeAmount totalAmount currency status providerReceipt confirmedAt createdAt').lean(),
    PlatformFeeLedger.countDocuments(filter),
    PlatformFeeLedger.aggregate([{$match:filter},{$group:{_id:'$status',count:{$sum:1},feeAmount:{$sum:'$feeAmount'}}}]),
  ]);
  r.json({fees,total,page,limit,summary:summary.map(item=>({status:item._id,count:item.count,feeAmount:item.feeAmount}))});
});
app.put('/api/admin/platform-fee-settings',auth,requireAdmin,async(q,r)=>{
  const body=q.body||{};
  const walletType=String(body.walletType||'');
  const feeRate=Number(body.feeRate);
  const walletPhone=String(body.walletPhone||'').trim().replace(/^\+/,'');
  const paybillNumber=String(body.paybillNumber||'').trim();
  const tillNumber=String(body.tillNumber||'').trim();
  const accountReference=String(body.accountReference||'CHATIFY-FEE').trim().slice(0,80);
  if(!['mpesa_phone','mpesa_paybill','mpesa_till'].includes(walletType))return r.status(400).json({error:'Choose an M-Pesa phone, Paybill or Till wallet'});
  if(!Number.isFinite(feeRate)||feeRate<0||feeRate>5)return r.status(400).json({error:'Fee rate must be between 0 and 5 percent'});
  if(walletType==='mpesa_phone'&&!/^254[17][0-9]{8}$/.test(walletPhone))return r.status(400).json({error:'Enter the platform wallet phone in 254XXXXXXXXX format'});
  if(walletType==='mpesa_paybill'&&!/^[0-9]{5,10}$/.test(paybillNumber))return r.status(400).json({error:'Enter a valid platform Paybill number'});
  if(walletType==='mpesa_till'&&!/^[0-9]{5,10}$/.test(tillNumber))return r.status(400).json({error:'Enter a valid platform Till number'});
  const settings=await PlatformFeeSettings.findOneAndUpdate({key:'global'},{$set:{enabled:body.enabled!==false,feeRate,walletType,walletPhone:walletType==='mpesa_phone'?walletPhone:'',paybillNumber:walletType==='mpesa_paybill'?paybillNumber:'',tillNumber:walletType==='mpesa_till'?tillNumber:'',accountReference,updatedBy:q.user._id}},{new:true,upsert:true,runValidators:true,setDefaultsOnInsert:true});
  r.json({settings});
});
app.post('/api/auth/forgot-password',recoveryRateLimit,async(q,r)=>{
  const email=typeof q.body?.email==='string'?q.body.email.trim().toLowerCase():'';
  if(email.length>254||!/^\S+@\S+\.\S+$/.test(email))return r.status(400).json({error:'Enter a valid email address'});
  if(production&&!emailProvider.available)return r.status(503).json({error:'Password reset email is not configured'});
  const user=await User.findOne({email});
  if(user){
    await PasswordReset.deleteMany({userId:user._id});
    const token=createResetToken();const tokenHash=hashResetToken(token);const expiresAt=resetExpiry();
    await PasswordReset.create({userId:user._id,tokenHash,expiresAt});
    try{await emailProvider.sendPasswordReset({email:user.email,token,expiresAt});}
    catch{await PasswordReset.deleteOne({tokenHash});console.error('Password reset email delivery failed');}
  }
  r.json({message:'If the account exists and email delivery succeeds, reset instructions will be sent.'});
});
app.post('/api/auth/reset-password',recoveryRateLimit,async(q,r)=>{const {token,newPassword}=q.body||{};if(!validPassword(newPassword))return r.status(400).json({error:'New password must be 8–72 UTF-8 bytes'});if(typeof token!=='string'||token.length>200)return r.status(400).json({error:'A valid reset token is required'});const reset=await PasswordReset.findOneAndDelete({tokenHash:hashResetToken(token),expiresAt:{$gt:new Date()}});if(!reset)return r.status(400).json({error:'Reset token is invalid or expired'});await User.findByIdAndUpdate(reset.userId,{$set:{passwordHash:await bcrypt.hash(newPassword,12)},$inc:{sessionVersion:1}});await PasswordReset.deleteMany({userId:reset.userId});revokeUserSockets(reset.userId);r.json({ok:true});});
app.post('/api/auth/change-password',auth,async(q,r)=>{const {currentPassword,newPassword}=q.body||{};if(!validPassword(newPassword))return r.status(400).json({error:'New password must be 8–72 UTF-8 bytes'});if(!(await bcrypt.compare(currentPassword||'',q.user.passwordHash)))return r.status(401).json({error:'Current password is incorrect'});q.user.passwordHash=await bcrypt.hash(newPassword,12);q.user.sessionVersion=(q.user.sessionVersion||0)+1;await q.user.save();revokeUserSockets(q.user._id);r.json({ok:true,token:sign(q.user)});});
app.post('/api/users/:id/block',auth,async(q,r)=>{if(String(q.params.id)===String(q.user._id))return r.status(400).json({error:'Cannot block yourself'});const u=await User.findById(q.params.id);if(!u)return r.status(404).json({error:'User not found'});q.user.blockedUsers.addToSet(u._id);await q.user.save();r.json({ok:true});});
app.delete('/api/users/:id/block',auth,async(q,r)=>{q.user.blockedUsers.pull(q.params.id);await q.user.save();r.json({ok:true});});
app.get('/api/users/blocked',auth,async(q,r)=>r.json({users:await User.find({_id:{$in:q.user.blockedUsers}}).select('name email profileImage')}));
// CONTACT ROUTES: manage saved contacts while filtering inactive, self and blocked accounts.
app.get('/api/contacts',auth,async(q,r)=>{const page=Math.max(1,Number.parseInt(q.query.page,10)||1),limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||20));const filter={userId:q.user._id};const [saved,total]=await Promise.all([SavedContact.find(filter).sort({createdAt:-1}).skip((page-1)*limit).limit(limit).populate('contactUserId','name email phone profileImage status'),SavedContact.countDocuments(filter)]);r.json({contacts:saved.filter(c=>c.contactUserId&&c.contactUserId.status==='active').map(c=>({id:String(c._id),name:c.nameOverride||c.contactUserId.name,email:c.contactUserId.email,phone:c.contactUserId.phone,profileImage:c.contactUserId.profileImage,userId:String(c.contactUserId._id)})),total,page,limit});});
app.get('/api/contacts/search',auth,async(q,r)=>{const raw=q.query.q;if(typeof raw!=='string')return r.status(400).json({error:'Enter a phone number'});const digits=raw.replace(/\D/g,'');if(digits.length<3||digits.length>15)return r.json({users:[]});let prefix=digits;if(digits.startsWith('0'))prefix='254'+digits.slice(1);else if(digits.startsWith('254'))prefix=digits;else if(digits.startsWith('7')||digits.startsWith('1'))prefix='254'+digits;else return r.json({users:[]});const users=await User.find({phone:{$regex:'^'+prefix},status:'active',_id:{$ne:q.user._id,$nin:q.user.blockedUsers||[]}}).select('name email phone profileImage status blockedUsers').limit(10);const visible=[];for(const user of users){if((user.blockedUsers||[]).some(id=>String(id)===String(q.user._id)))continue;visible.push(visibleUser(user));}r.json({users:visible});});
app.post('/api/contacts',auth,async(q,r)=>{let person;const requestedUserId=q.body?.userId;if(typeof requestedUserId==='string'){if(!mongoose.isValidObjectId(requestedUserId))return r.status(400).json({error:'Invalid Chatify user'});person=await User.findOne({_id:{$eq:requestedUserId,$ne:q.user._id,$nin:q.user.blockedUsers||[]},status:'active'}).select('_id name status blockedUsers');}else{const raw=q.body?.phone;if(typeof raw!=='string')return r.status(400).json({error:'Provide a phone number or Chatify user'});const phone=normalizeMpesaPhone(raw);if(!phone)return r.status(400).json({error:'Enter a valid Kenyan phone number'});person=await User.findOne({phone,status:'active',_id:{$ne:q.user._id,$nin:q.user.blockedUsers||[]}}).select('_id name status blockedUsers');}if(!person)return r.status(404).json({error:'No Chatify account was found'});if((person.blockedUsers||[]).some(id=>String(id)===String(q.user._id)))return r.status(404).json({error:'No Chatify account was found'});let saved;try{saved=await SavedContact.create({userId:q.user._id,contactUserId:person._id});}catch(error){if(error.code!==11000)throw error;saved=await SavedContact.findOne({userId:q.user._id,contactUserId:person._id});}await saved.populate('contactUserId','name email phone profileImage status');r.status(201).json({contact:{id:String(saved._id),name:saved.contactUserId.name,email:saved.contactUserId.email,phone:saved.contactUserId.phone,profileImage:saved.contactUserId.profileImage,userId:String(saved.contactUserId._id)}});});
app.delete('/api/contacts/:id',auth,async(q,r)=>{if(!mongoose.isValidObjectId(q.params.id))return r.status(400).json({error:'Invalid contact'});const result=await SavedContact.deleteOne({_id:q.params.id,userId:q.user._id});if(!result.deletedCount)return r.status(404).json({error:'Contact not found'});r.status(204).end();});
app.get('/api/users/search',auth,async(q,r)=>{const raw=q.query.q;if(raw!=null&&typeof raw!=='string')return r.status(400).json({error:'Search query must be text'});const term=(raw||'').trim();if(term.length<2)return r.json({users:[]});if(term.length>80)return r.status(400).json({error:'Search query must be 80 characters or fewer'});const escaped=term.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');const users=await User.find({$or:[{name:{$regex:escaped,$options:'i'}},{email:{$regex:escaped,$options:'i'}}],_id:{$ne:q.user._id,$nin:q.user.blockedUsers||[]},status:'active'}).select('name email profileImage status lastSeen privacy').limit(20);r.json({users:users.map(visibleUser)});});
app.patch('/api/users/me',auth,async(q,r)=>{const b=q.body||{};if('name'in b&&(typeof b.name!=='string'||!b.name.trim()||b.name.trim().length>80))return r.status(400).json({error:'Name must be between 1 and 80 characters'});if('phone'in b&&!normalizeMpesaPhone(b.phone))return r.status(400).json({error:'Enter a valid Kenyan M-Pesa phone number'});if('profileImage'in b&&b.profileImage!=null&&(typeof b.profileImage!=='string'||b.profileImage.length>2048||!/^https:\/\//i.test(b.profileImage)))return r.status(400).json({error:'Profile image must be a secure URL'});for(const [key,allowed] of [['privacy',['lastSeen','readReceipts']],['notificationPreferences',['messages','mentions','memories']]])if(key in b){if(!b[key]||typeof b[key]!=='object'||Array.isArray(b[key])||Object.keys(b[key]).some(k=>!allowed.includes(k))||Object.values(b[key]).some(v=>typeof v!=='boolean'))return r.status(400).json({error:`Invalid ${key} settings`});q.user[key]={...q.user[key]?.toObject?.(),...b[key]};}for(const k of ['name','phone','profileImage'])if(k in b)q.user[k]=k==='name'?b[k].trim():k==='phone'?normalizeMpesaPhone(b[k]):b[k];await q.user.save();r.json({user:safe(q.user)});});
app.post('/api/devices',auth,async(q,r)=>{
  const token=typeof q.body?.token==='string'?q.body.token.trim():'';
  if(!token||token.length>4096)return r.status(400).json({error:'A valid push registration token is required'});
  if(!q.user.pushTokens.includes(token)&&q.user.pushTokens.length>=20)return r.status(400).json({error:'At most 20 devices can be registered'});
  q.user.pushTokens.addToSet(token);await q.user.save();r.status(204).end();
});
app.delete('/api/devices',auth,async(q,r)=>{
  const token=typeof q.body?.token==='string'?q.body.token.trim():'';
  if(!token||token.length>4096)return r.status(400).json({error:'A valid push registration token is required'});
  q.user.pushTokens.pull(token);await q.user.save();r.status(204).end();
});
// CONVERSATION ROUTES: lookups are scoped to membership so users cannot read unrelated chats.
app.get('/api/conversations',auth,async(q,r)=>{
 const page=Math.max(1,Number.parseInt(q.query.page,10)||1),limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||20));
 const filter={participants:q.user._id,hiddenFor:{$ne:q.user._id}};
 const cursor=typeof q.query.cursor==='string'?q.query.cursor:'';
 if(cursor){try{const d=JSON.parse(Buffer.from(cursor,'base64url').toString('utf8'));const date=new Date(d.updatedAt);if(!Number.isFinite(date.getTime())||!mongoose.isValidObjectId(String(d.id||'')))throw new Error('invalid');filter.$or=[{updatedAt:{$lt:date}},{updatedAt:date,_id:{$lt:new mongoose.Types.ObjectId(d.id)}}];}catch{return r.status(400).json({error:'Invalid conversation pagination cursor'});}}
 let query=Conversation.find(filter).sort({updatedAt:-1,_id:-1}).limit(limit+1).populate('participants','name email phone profileImage status lastSeen privacy encryptionPublicKey');
 if(!cursor&&page>1)query=query.skip((page-1)*limit);
 const rows=await query,hasMore=rows.length>limit,conversations=hasMore?rows.slice(0,limit):rows,last=conversations[conversations.length-1];
 const nextCursor=hasMore&&last?Buffer.from(JSON.stringify({updatedAt:last.updatedAt,id:String(last._id)})).toString('base64url'):null;
 const total=await Conversation.countDocuments({participants:q.user._id,hiddenFor:{$ne:q.user._id}});
 r.json({conversations:conversations.map(c=>{const value=c.toObject();value.participants=value.participants.map(visibleUser);return value;}),total,page,limit,nextCursor,hasMore});
});
app.post('/api/conversations/delete',auth,async(q,r)=>{const ids=Array.isArray(q.body?.conversationIds)?[...new Set(q.body.conversationIds.map(String))]:[];if(!ids.length||ids.length>100||ids.some(id=>!mongoose.isValidObjectId(id)))return r.status(400).json({error:'Select between 1 and 100 valid conversations'});const found=await Conversation.find({_id:{$in:ids},participants:q.user._id});if(found.length!==ids.length)return r.status(404).json({error:'One or more conversations were not found'});await Conversation.updateMany({_id:{$in:ids},participants:q.user._id},{$addToSet:{hiddenFor:q.user._id}});r.json({ok:true,deletedConversationIds:ids});});
app.get('/api/conversations/:id',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,participants:q.user._id,hiddenFor:{$ne:q.user._id}}).populate('participants','name email phone profileImage status lastSeen privacy encryptionPublicKey');if(!c)return r.status(404).json({error:'Conversation not found'});const value=c.toObject();value.participants=value.participants.map(visibleUser);r.json({conversation:value});});
app.post('/api/conversations/direct',auth,async(q,r)=>{if(!mongoose.isValidObjectId(q.body?.userId)||String(q.body.userId)===String(q.user._id))return r.status(400).json({error:'Choose another valid user'});const other=await User.findById(q.body.userId);if(!other||String(other._id)===String(q.user._id))return r.status(404).json({error:'User not found'});if(q.user.blockedUsers.some(x=>String(x)===String(other._id))||other.blockedUsers.some(x=>String(x)===String(q.user._id)))return r.status(403).json({error:'This conversation is unavailable'});const directKey=[String(q.user._id),String(other._id)].sort().join(':');let c=await Conversation.findOne({directKey});if(!c){try{c=await Conversation.create({type:'direct',directKey,participants:[q.user._id,other._id]});}catch(error){if(error.code!==11000)throw error;c=await Conversation.findOne({directKey});if(!c)throw error;}}c.hiddenFor.pull(q.user._id);await c.save();io.in('user:'+String(q.user._id)).socketsJoin(String(c._id));io.in('user:'+String(other._id)).socketsJoin(String(c._id));await c.populate('participants','name email phone profileImage status lastSeen privacy encryptionPublicKey');const value=c.toObject();value.participants=value.participants.map(visibleUser);r.status(201).json({conversation:value});});
app.post('/api/conversations/group',auth,async(q,r)=>{const memberIds=Array.isArray(q.body?.memberIds)?q.body.memberIds:[];const ids=[String(q.user._id),...memberIds.map(String)];const unique=[...new Set(ids)];const title=typeof q.body?.title==='string'?q.body.title.trim():'';if(!title||title.length>80||unique.length<2||unique.length>50||unique.some(id=>!mongoose.isValidObjectId(id)))return r.status(400).json({error:'Group title and 1–49 valid members are required'});const found=await User.find({_id:{$in:unique},status:'active'}).select('_id');if(found.length!==unique.length)return r.status(400).json({error:'One or more members could not be found'});if(memberIds.some(id=>q.user.blockedUsers.some(b=>String(b)===String(id))))return r.status(403).json({error:'A selected member is blocked'});const c=await Conversation.create({type:'group',participants:unique,title,description:String(q.body.description||'').slice(0,500),admins:[q.user._id]});for(const id of unique)io.in('user:'+id).socketsJoin(String(c._id));await c.populate('participants','name email phone profileImage status lastSeen privacy encryptionPublicKey');const value=c.toObject();value.participants=value.participants.map(visibleUser);r.status(201).json({conversation:value});});
app.post('/api/conversations/:id/members',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,admins:q.user._id,type:'group'});if(!c)return r.status(403).json({error:'Group admin required'});if(!mongoose.isValidObjectId(q.body?.userId)||!await User.exists({_id:q.body.userId,status:'active'}))return r.status(400).json({error:'Choose a valid active user'});if(q.user.blockedUsers.some(x=>String(x)===String(q.body.userId)))return r.status(403).json({error:'This user is blocked'});if(!c.participants.some(id=>String(id)===String(q.body.userId))&&c.participants.length>=50)return r.status(400).json({error:'Groups can have at most 50 members'});c.participants.addToSet(q.body.userId);await c.save();io.in('user:'+String(q.body.userId)).socketsJoin(String(c._id));emitConversationEvent(c,'conversation:updated',c);r.json({conversation:c});});
app.delete('/api/conversations/:id/members/:userId',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,admins:q.user._id,type:'group'});if(!c)return r.status(403).json({error:'Group admin required'});if(!c.participants.some(x=>String(x)===q.params.userId))return r.status(404).json({error:'Member not found'});if(String(q.user._id)===q.params.userId&&c.admins.length===1&&c.participants.length>1)return r.status(400).json({error:'Promote another admin before leaving'});c.participants.pull(q.params.userId);c.admins.pull(q.params.userId);await c.save();leaveUserConversation(q.params.userId,c._id);emitConversationEvent(c,'conversation:updated',c);r.json({conversation:c});});
app.post('/api/conversations/:id/admins/:userId',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,admins:q.user._id});if(!c)return r.status(403).json({error:'Group admin required'});if(!c.participants.some(x=>String(x)===q.params.userId))return r.status(400).json({error:'User is not a member'});c.admins.addToSet(q.params.userId);await c.save();r.json({conversation:c});});
app.delete('/api/conversations/:id/admins/:userId',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,admins:q.user._id,type:'group'});if(!c)return r.status(403).json({error:'Group admin required'});if(!c.admins.some(id=>String(id)===q.params.userId))return r.status(404).json({error:'Group admin not found'});if(q.params.userId===String(q.user._id)&&c.admins.length===1&&c.participants.length>1)return r.status(400).json({error:'Promote another admin before removing your role'});c.admins.pull(q.params.userId);await c.save();emitConversationEvent(c,'conversation:updated',c);r.json({conversation:c});});
app.post('/api/conversations/:id/leave',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,participants:q.user._id,type:'group'});if(!c)return r.status(404).json({error:'Group conversation not found'});if(c.admins.some(x=>String(x)===String(q.user._id))&&c.admins.length===1&&c.participants.length>1)return r.status(400).json({error:'Promote another admin before leaving'});c.participants.pull(q.user._id);c.admins.pull(q.user._id);await c.save();leaveUserConversation(q.user._id,c._id);emitConversationEvent(c,'conversation:updated',c);r.json({ok:true});});
// MESSAGE ROUTES: check membership before reading/changing messages, receipts, reactions and expiry.
app.get('/api/conversations/:id/messages',auth,async(q,r)=>{
 const c=await Conversation.findOne({_id:q.params.id,participants:q.user._id,hiddenFor:{$ne:q.user._id}});
 if(!c)return r.status(404).json({error:'Conversation not found'});
 const filter={conversationId:c._id,expiredAt:{$exists:false},hiddenFor:{$ne:q.user._id}};
 if(q.query.q){const term=String(q.query.q).trim().slice(0,100);if(term){const escaped=term.replace(/[.*+?^$()|[\]\\{}]/g,'\\$&');filter.text={$regex:escaped,$options:'i'};}}
 const countFilter={...filter};
 const page=Math.max(1,Number.parseInt(q.query.page,10)||1),limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||40));
 const cursor=typeof q.query.cursor==='string'?q.query.cursor:'';
 if(cursor){try{const d=JSON.parse(Buffer.from(cursor,'base64url').toString('utf8'));const date=new Date(d.createdAt);if(!Number.isFinite(date.getTime())||!mongoose.isValidObjectId(String(d.id||'')))throw new Error('invalid');filter.$or=[{createdAt:{$lt:date}},{createdAt:date,_id:{$lt:new mongoose.Types.ObjectId(d.id)}}];}catch{return r.status(400).json({error:'Invalid message pagination cursor'});}}
 let query=Message.find(filter).sort({createdAt:-1,_id:-1}).limit(limit+1);
 if(!cursor&&page>1)query=query.skip((page-1)*limit);
 const [rows,total]=await Promise.all([query,Message.countDocuments(countFilter)]);
 const hasMore=rows.length>limit,descending=hasMore?rows.slice(0,limit):rows,last=descending[descending.length-1];
 const nextCursor=hasMore&&last?Buffer.from(JSON.stringify({createdAt:last.createdAt,id:String(last._id)})).toString('base64url'):null;
 r.json({messages:descending.reverse(),total,page,limit,nextCursor,hasMore});
});
app.post('/api/conversations/:id/messages',auth,async(q,r)=>{const c=await Conversation.findOne({_id:q.params.id,participants:q.user._id});if(!c)return r.status(404).json({error:'Conversation not found'});if(c.type==='direct'){const others=c.participants.filter(id=>String(id)!==String(q.user._id));const blocked=await User.exists({_id:{$in:others},blockedUsers:q.user._id});if(blocked||q.user.blockedUsers.some(id=>others.some(other=>String(other)===String(id))))return r.status(403).json({error:'This conversation is unavailable'});}const {text,messageType='text',replyTo,expiryType='NONE',expiresInSeconds,encryptionVersion,encryptedPayload}=q.body||{};if(!['text','image','file'].includes(messageType)||!['NONE','AFTER_READ','AFTER_TIME','AFTER_REPLY'].includes(expiryType))return r.status(400).json({error:'Unsupported message or expiration type'});const isEncrypted=encryptionVersion===1&&isValidEncryptedPayload(encryptedPayload,c.participants.map(id=>String(id)));if(messageType==='text'&&!isEncrypted)return r.status(400).json({error:'Text messages must contain valid end-to-end encrypted envelopes for every conversation member. Update Chatify and register all member keys.'});if(messageType==='text'&&text!==undefined)return r.status(400).json({error:'Do not send plaintext text alongside encrypted message content.'});const mediaUrl=q.body?.mediaUrl;if(messageType!=='text'&&!isAllowedMessageMediaUrl(mediaUrl,production))return r.status(400).json({error:'A secure image URL or supported mock image is required'});if(replyTo){const parent=await Message.findOne({_id:replyTo,conversationId:c._id,expiredAt:{$exists:false}});if(!parent)return r.status(400).json({error:'Reply target is unavailable'});if(expiresWhenRepliedTo(parent)){parent.expiredAt=new Date();parent.text='';parent.encryptedPayload=null;parent.mediaUrl=null;await parent.save();emitConversationEvent(c,'message:expired',{messageId:parent._id});}}const m=await Message.create({conversationId:c._id,senderId:q.user._id,...(isEncrypted?{encryptedPayload,encryptionVersion:1}:{}),messageType,mediaUrl,replyTo,expiryType,expiresAt:messageExpiry(expiryType,expiresInSeconds),readBy:[q.user._id],deliveredTo:[q.user._id]});c.hiddenFor=unhideConversationForUser(c.hiddenFor,q.user._id);c.lastMessage={text:isEncrypted?'🔒 Encrypted message':(m.text||messageType),senderId:q.user._id,createdAt:m.createdAt};await c.save();emitConversationEvent(c,'message:new',m);const recipientIds=c.participants.filter(id=>String(id)!==String(q.user._id));const recipients=await User.find({_id:{$in:recipientIds},'notificationPreferences.messages':{$ne:false}}).select('_id').lean();if(recipients.length)await NotificationJob.bulkWrite(recipients.map(recipient=>({updateOne:{filter:{recipientId:recipient._id,messageId:m._id},update:{$setOnInsert:{recipientId:recipient._id,messageId:m._id,conversationId:c._id,status:'queued',availableAt:new Date(),attempts:0}},upsert:true}})),{ordered:false}).catch(error=>{if(error.code!==11000&&!error.writeErrors?.every(item=>item.code===11000))throw error;});r.status(201).json({message:m});});
app.delete('/api/messages/:id',auth,async(q,r)=>{const m=await Message.findById(q.params.id);if(!m)return r.status(404).json({error:'Message not found'});const c=await Conversation.findOne({_id:m.conversationId,participants:q.user._id});if(!c)return r.status(403).json({error:'Forbidden'});if(q.query.scope==='me'){m.hiddenFor.addToSet(q.user._id);await m.save();return r.json({hidden:true,id:String(m._id)});}if(String(m.senderId)!==String(q.user._id))return r.status(403).json({error:'You can only delete messages you sent'});if(m.expiredAt)return r.status(409).json({error:'This message has already expired'});if(!m.deletedAt){m.deletedAt=new Date();m.text='';m.encryptedPayload=undefined;m.mediaUrl=null;m.messageType='text';m.reactions=[];await m.save();if(String(c.lastMessage?.senderId)===String(m.senderId)&&String(c.lastMessage?.createdAt)===String(m.createdAt)){c.lastMessage={text:'This message was deleted',senderId:m.senderId,createdAt:m.createdAt};await c.save();}emitConversationEvent(c,'message:deleted',{messageId:String(m._id),conversationId:String(c._id),deletedAt:m.deletedAt});}r.json({message:m});});
app.post('/api/messages/:id/reactions',auth,async(q,r)=>{const m=await Message.findById(q.params.id);if(!m)return r.status(404).json({error:'Message not found'});const c=await Conversation.findOne({_id:m.conversationId,participants:q.user._id});if(!c)return r.status(403).json({error:'Forbidden'});if(!['👍','❤️','😂','😮','😢','🙏'].includes(q.body.emoji))return r.status(400).json({error:'Unsupported reaction'});m.reactions=m.reactions.filter(x=>String(x.userId)!==String(q.user._id));m.reactions.push({userId:q.user._id,emoji:q.body.emoji});await m.save();emitConversationEvent(c,'message:reaction',m);r.json({message:m});});
app.post('/api/messages/:id/delivered',auth,async(q,r)=>{const m=await Message.findById(q.params.id);if(!m)return r.status(404).json({error:'Message not found'});const c=await Conversation.findOne({_id:m.conversationId,participants:q.user._id});if(!c)return r.status(403).json({error:'Forbidden'});m.deliveredTo.addToSet(q.user._id);await m.save();emitConversationEvent(c,'message:delivered',{messageId:m._id,userId:q.user._id});r.json({ok:true});});
app.post('/api/messages/:id/read',auth,async(q,r)=>{const m=await Message.findById(q.params.id);if(!m)return r.status(404).json({error:'Message not found'});const c=await Conversation.findOne({_id:m.conversationId,participants:q.user._id});if(!c)return r.status(403).json({error:'Forbidden'});const shareReceipt=q.user.privacy?.readReceipts!==false;if(shareReceipt&&!m.readBy.some(x=>String(x)===String(q.user._id)))m.readBy.push(q.user._id);if(m.expiryType==='AFTER_READ'&&String(m.senderId)!==String(q.user._id)){m.expiredAt=new Date();m.text='';m.encryptedPayload=null;m.mediaUrl=null;}await m.save();if(m.expiredAt)emitConversationEvent(c,'message:expired',{messageId:m._id});else if(shareReceipt)emitConversationEvent(c,'message:read',{messageId:m._id,userId:q.user._id});r.json({ok:true});});
// PAYMENT ACCESS HELPERS: only authorized participants can view a request.
const paymentAllowed=async(payment,userId)=>{if(!payment)return false;const member=!payment.conversationId||Boolean(await Conversation.exists({_id:payment.conversationId,participants:userId}));return canAccessPayment(payment,userId,member);};
const emitPayment=payment=>{const data=payment.toObject?payment.toObject():payment;io.to('user:'+String(data.requesterId)).emit('payment:updated',data);io.to('user:'+String(data.payerId)).emit('payment:updated',data);};
// PAYMENT ROUTES: create/manage requests; real success must be confirmed by a verified Daraja callback.
app.post('/api/payments',auth,async(q,r)=>{const b=q.body||{};const payerId=b.payerUserId;if(!mongoose.isValidObjectId(payerId)||String(payerId)===String(q.user._id)||!validPaymentAmount(b.amount)||typeof b.description!=='string'||!b.description.trim()||b.description.trim().length>80)return r.status(400).json({error:'Choose another payer, a whole KSh amount from 1 to 150000, and a description of 1 to 80 characters'});const recipientPhone=normalizeMpesaPhone(b.recipientPhone);if(!recipientPhone)return r.status(400).json({error:'Enter a valid Kenyan recipient M-Pesa phone number'});const payerUser=await User.findOne({_id:payerId,status:'active'}).select('phone');if(!payerUser)return r.status(404).json({error:'Payer not found'});const payerPhone=normalizeMpesaPhone(b.payerPhone===undefined?payerUser.phone:b.payerPhone);if(!payerPhone)return r.status(400).json({error:'Enter a valid Kenyan payer M-Pesa phone number'});let conversationId;if(b.conversationId){if(!mongoose.isValidObjectId(b.conversationId))return r.status(400).json({error:'Invalid conversation'});const c=await Conversation.findOne({_id:b.conversationId,participants:{$all:[q.user._id,payerId]}});if(!c)return r.status(403).json({error:'Both users must belong to the conversation'});conversationId=c._id;}// User-to-user transfers are not platform-fee eligible; Safaricom's own charges remain separate.
const fee=calculatePaymentTotal(b.amount,{applicable:false});const payment=await Payment.create({paymentId:newPaymentId(),requesterId:q.user._id,payerId,conversationId,amount:b.amount,...fee,recipientPhone,payerPhone,description:b.description.trim(),provider:mpesaProvider.name,requestedAt:new Date()});emitPayment(payment);r.status(201).json({payment});});
// Let a signed-in user initiate an STK prompt on their own phone to pay the configured business shortcode.
app.post('/api/payments/send-stk',auth,async(q,r)=>{
  const b=q.body||{};
  const phone=normalizeMpesaPhone(b.phone);
  if(!phone||!validPaymentAmount(b.amount)||typeof b.description!=='string'||!b.description.trim()||b.description.trim().length>80)
    return r.status(400).json({error:'Enter a valid Kenyan M-Pesa number, a whole KSh amount from 1 to 150000, and a description up to 80 characters'});
  // Generic self-STK is not a business invoice or school-fee checkout, so it is fee-free.
  const fee=calculatePaymentTotal(b.amount,{applicable:false});
  let conversationId;
  if(b.conversationId){
    if(!mongoose.isValidObjectId(b.conversationId))return r.status(400).json({error:'Invalid conversation'});
    const conversation=await Conversation.findOne({_id:b.conversationId,participants:q.user._id});
    if(!conversation)return r.status(403).json({error:'Conversation access required'});
    conversationId=conversation._id;
  }
  // The user is both the initiator and payer for this merchant-directed checkout.
  // This is intentionally separate from /api/payments, which requests money from another user.
  const payment=await Payment.create({
    paymentId:newPaymentId(),requesterId:q.user._id,payerId:q.user._id,conversationId,
    amount:b.amount,...fee,recipientPhone:process.env.MPESA_SHORTCODE||'BUSINESS_SHORTCODE',
    payerPhone:phone,phone,description:b.description.trim(),purpose:'SELF_STK',
    provider:mpesaProvider.name,requestedAt:new Date(),initiating:true
  });
  try{
    const refs=await mpesaProvider.initiate({paymentId:payment.paymentId,amount:payment.totalAmount??payment.amount,phone,description:payment.description});
    payment.checkoutRequestId=refs.checkoutRequestId;payment.merchantRequestId=refs.merchantRequestId;
    payment.initiatedAt=new Date();payment.initiating=false;await payment.save();emitPayment(payment);
    return r.json({payment,mock:mpesaProvider.isMock});
  }catch(error){
    console.error('Self-initiated M-Pesa STK failed',{provider:mpesaProvider.name,paymentId:payment.paymentId,stage:error?.stage||'configuration_or_unknown'});
    payment.initiating=false;payment.resultDescription='STK initiation failed';await payment.save();
    const stage=error?.stage;
    const message=mpesaProvider.isMock?'Local demo mode is active. No real Safaricom prompt was sent.':stage==='oauth_transport'?'Could not reach Safaricom authentication. Check backend connectivity.':stage==='oauth_auth'?'Safaricom authentication failed. Verify the Daraja consumer key and secret.':stage==='stk_transport'?'Could not reach Safaricom STK Push. Check backend connectivity.':stage==='stk_rejected'?'Safaricom rejected the STK request. Verify shortcode, passkey, transaction type, phone and callback URL.':'M-Pesa could not start the STK prompt. Check backend logs and Daraja configuration.';
    return r.status(503).json({error:message});
  }
});
app.post('/api/payments/:id/initiate',auth,async(q,r)=>{const payerPhone=normalizeMpesaPhone(q.body?.phone);if(!payerPhone)return r.status(400).json({error:'Enter the M-Pesa phone number that should receive the payment prompt'});let payment=await Payment.findOne({paymentId:q.params.id});if(!payment||String(payment.payerId)!==String(q.user._id)||!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});// Personal payment requests have no platform fee, so no fee acknowledgement is required.if(payment.status!=='PENDING')return r.status(409).json({error:'Only pending payments can be initiated'});payment=await Payment.findOneAndUpdate({_id:payment._id,status:'PENDING',initiatedAt:{$exists:false},initiating:{$ne:true}},{$set:{initiating:true,phone:payerPhone,payerPhone}},{new:true});if(!payment)return r.status(409).json({error:'This payment is already being initiated or was initiated'});try{const refs=await mpesaProvider.initiate({paymentId:payment.paymentId,amount:(payment.baseAmount??payment.amount),phone:payerPhone,description:payment.description});payment.checkoutRequestId=refs.checkoutRequestId;payment.merchantRequestId=refs.merchantRequestId;payment.initiatedAt=new Date();payment.initiating=false;await payment.save();emitPayment(payment);r.json({payment,mock:mpesaProvider.isMock});}catch(error){console.error('M-Pesa STK initiation failed',{provider:mpesaProvider.name,paymentId:payment.paymentId,stage:error?.stage||'configuration_or_unknown'});await Payment.updateOne({_id:payment._id,status:'PENDING'},{$set:{initiating:false}});const stage=error?.stage;const message=mpesaProvider.isMock?'Local demo payment could not start. Mock mode never sends a real Safaricom prompt.':stage==='oauth_transport'?'Could not reach Safaricom authentication. Check server connectivity and Daraja availability.':stage==='oauth_auth'?'Safaricom authentication failed. Verify the Daraja consumer key and consumer secret in the backend environment.':stage==='stk_transport'?'Could not reach Safaricom STK Push. Check server connectivity and Daraja availability.':stage==='stk_rejected'?'Safaricom rejected the STK request. Verify the shortcode, passkey, transaction type, phone number and public HTTPS callback URL.':'M-Pesa could not start the STK prompt. Check the backend deployment logs and Daraja configuration before retrying.';r.status(503).json({error:message});}});
app.get('/api/payments',auth,async(q,r)=>{const rows=await Payment.find({$or:[{requesterId:q.user._id},{payerId:q.user._id}]}).sort({createdAt:-1}).limit(100);const payments=[];for(const payment of rows)if(await paymentAllowed(payment,q.user._id))payments.push(payment);r.json({payments});});
app.get('/api/payments/:id',auth,async(q,r)=>{const payment=await Payment.findOne({paymentId:q.params.id});if(!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});r.json({payment});});
app.post('/api/payments/:id/close',auth,async(q,r)=>{const payment=await Payment.findOne({paymentId:q.params.id});if(!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});const updated=await Payment.findOneAndUpdate({_id:payment._id},{$addToSet:{dismissedBy:q.user._id}},{new:true});emitPayment(updated||payment);r.json({payment:updated||payment});});
app.post('/api/payments/:id/reopen',auth,async(q,r)=>{const payment=await Payment.findOne({paymentId:q.params.id});if(!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});const updated=await Payment.findOneAndUpdate({_id:payment._id},{$pull:{dismissedBy:q.user._id}},{new:true});emitPayment(updated||payment);r.json({payment:updated||payment});});
app.post('/api/payments/:id/reject',auth,async(q,r)=>{const payment=await Payment.findOne({paymentId:q.params.id});if(!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});if(!canCancelPayment(payment,q.user._id,true))return r.status(409).json({error:'This request can only be rejected before an M-Pesa prompt is initiated. If a prompt was already sent, close it for yourself and cancel it on your phone if it is still open.'});const byPayer=String(q.user._id)===String(payment.payerId);const updated=await Payment.findOneAndUpdate({_id:payment._id,status:'PENDING',initiatedAt:{$exists:false},initiating:{$ne:true}},{$set:{status:'CANCELLED',resultDescription:byPayer?'Request rejected by payer':'Request withdrawn by requester',completedAt:new Date(),callbackProcessedAt:new Date()},$addToSet:{dismissedBy:q.user._id}},{new:true});if(!updated)return r.status(409).json({error:'This request has already started or has been closed'});emitPayment(updated);r.json({payment:updated});});
app.post('/api/payments/:id/mock-result',auth,async(q,r)=>{if(!mpesaProvider.isMock)return r.status(404).json({error:'Payment not found'});if(!['SUCCESS','FAILED','CANCELLED'].includes(q.body?.status))return r.status(400).json({error:'Choose SUCCESS, FAILED or CANCELLED'});const payment=await Payment.findOne({paymentId:q.params.id});if(!payment||String(payment.payerId)!==String(q.user._id)||!payment.initiatedAt||!await paymentAllowed(payment,q.user._id))return r.status(404).json({error:'Payment not found'});const changed=await Payment.findOneAndUpdate({paymentId:payment.paymentId,status:'PENDING',provider:'mock'},{$set:{status:q.body.status,resultCode:q.body.status==='SUCCESS'?0:1,resultDescription:'Local mock result; not a Safaricom transaction',completedAt:new Date(),callbackProcessedAt:new Date()}},{new:true});if(!changed)return r.status(409).json({error:'Payment is already complete'});emitPayment(changed);r.json({payment:changed,mock:true});});
app.post('/api/payments/:id/retry',auth,async(q,r)=>{const previous=await Payment.findOne({paymentId:q.params.id});if(!previous||!canRetryPayment(previous,q.user._id,await paymentAllowed(previous,q.user._id)))return r.status(404).json({error:'Retry is unavailable for this payment'});const payment=await Payment.create({paymentId:newPaymentId(),requesterId:previous.requesterId,payerId:previous.payerId,conversationId:previous.conversationId,amount:previous.amount,baseAmount:previous.baseAmount??previous.amount,platformFee:previous.platformFee??0,totalAmount:previous.totalAmount??previous.amount,platformFeeRate:previous.platformFeeRate??0,platformFeeStatus:previous.platformFee>0?'PENDING_PAYMENT':(previous.platformFeeStatus??'NOT_APPLICABLE'),feeCollectionMode:previous.feeCollectionMode??'combined',recipientPhone:previous.recipientPhone,payerPhone:previous.payerPhone,phone:previous.payerPhone,businessOrganizationId:previous.businessOrganizationId,businessDocumentId:previous.businessDocumentId,description:previous.description,provider:mpesaProvider.name,requestedAt:new Date()});emitPayment(payment);r.status(201).json({payment});});
app.post('/api/payments/daraja/callback',async(q,r)=>{const cb=q.body?.Body?.stkCallback;if(!cb||typeof cb.CheckoutRequestID!=='string'||typeof cb.MerchantRequestID!=='string')return r.status(400).json({error:'Malformed callback'});const payment=await Payment.findOne({checkoutRequestId:cb.CheckoutRequestID,merchantRequestId:cb.MerchantRequestID,provider:{$in:['daraja-sandbox','daraja-production']},status:'PENDING',callbackProcessedAt:{$exists:false}});if(!payment){const completed=await Payment.findOne({checkoutRequestId:cb.CheckoutRequestID,merchantRequestId:cb.MerchantRequestID,provider:{$in:['daraja-sandbox','daraja-production']},status:'SUCCESS'});if(completed&&completed.billingType&&completed.billingWorkspaceId)await applyWorkspaceBillingPayment({mongoose,payment:completed});return r.json({ok:true,duplicate:true});}if(!canTransitionPayment(payment.status,payment.callbackProcessedAt))return r.json({ok:true,duplicate:true});const outcome=resolveCallbackOutcome(cb,payment);if(outcome.error==='malformed')return r.status(400).json({error:'Malformed callback'});if(outcome.error==='mismatch')return r.status(400).json({error:'Callback details did not match the initiated payment'});const updated=await Payment.findOneAndUpdate({_id:payment._id,status:'PENDING',callbackProcessedAt:{$exists:false},checkoutRequestId:cb.CheckoutRequestID,merchantRequestId:cb.MerchantRequestID},{$set:{status:outcome.status,resultCode:outcome.resultCode,resultDescription:outcome.description,completedAt:new Date(),callbackProcessedAt:new Date(),...(payment.platformFee?{platformFeeStatus:outcome.status==='SUCCESS'?'PENDING_SETTLEMENT':'FAILED'}:{})}},{new:true});if(updated){emitPayment(updated);if(updated.status==='SUCCESS'){if (updated.billingType && updated.billingWorkspaceId) { try { await applyWorkspaceBillingPayment({Payment, mongoose, payment: updated}); } catch (error) { console.error('Workspace billing payment confirmed but entitlement update failed', {paymentId: updated.paymentId}); } }}if(updated.status==='SUCCESS'&&updated.businessDocumentId&&mongoose.models.BusinessDocument){const BusinessDocument=mongoose.models.BusinessDocument;const paymentRecord={amount:updated.amount,method:'mpesa',reference:updated.paymentId,verified:true,recordedAt:new Date(),recordedBy:updated.requesterId};const nextPaid={$round:[{$add:[{$ifNull:['$paidAmount',0]},updated.amount]},2]};const document=await BusinessDocument.findOneAndUpdate({_id:updated.businessDocumentId,organizationId:updated.businessOrganizationId,'paymentRecords.reference':{$ne:updated.paymentId}},[{$set:{paymentRecords:{$concatArrays:[{$ifNull:['$paymentRecords',[]]},[paymentRecord]]},paidAmount:{$min:['$total',nextPaid]},status:{$cond:[{$gte:[nextPaid,'$total']},'paid','part_paid']}}}],{new:true});if(document)io.to(String(document.conversationId||'')).emit('business:document-updated',{documentId:String(document._id),number:document.number,status:document.status,total:document.total,paidAmount:document.paidAmount});}}r.json({ok:true});});
// MEMORY ROUTES: suggest structured candidates, then manage records owned by the current user.
// Claim a source message as seen before displaying a suggestion. A unique per-user/source ledger prevents repeats across app restarts and devices.
app.post('/api/memories/seen',auth,async(q,r)=>{
  const {conversationId,sourceMessageId}=q.body||{};
  if(!mongoose.isValidObjectId(conversationId)||!mongoose.isValidObjectId(sourceMessageId))return r.status(400).json({error:'A valid conversation and source message are required'});
  const conversation=await Conversation.findOne({_id:conversationId,participants:q.user._id});
  if(!conversation)return r.status(403).json({error:'Conversation access required'});
  const source=await Message.findOne({_id:sourceMessageId,conversationId:conversation._id});
  if(!source)return r.status(404).json({error:'Source message not found'});
  const existing=await MemorySuggestionSeen.findOne({userId:q.user._id,sourceMessageId}).lean();
  if(existing)return r.json({alreadySeen:true,status:existing.status});
  try {
    await MemorySuggestionSeen.create({userId:q.user._id,conversationId:conversation._id,sourceMessageId,status:'suggested'});
    return r.json({alreadySeen:false,status:'suggested'});
  } catch(error) {
    if(error?.code===11000)return r.json({alreadySeen:true,status:'suggested'});
    throw error;
  }
});
app.post('/api/memories/extract',auth,async(q,r)=>{
  const text=q.body?.text;
  if(typeof text!=='string'||!text.trim()||text.length>5000)return r.status(400).json({error:'Memory source text must be between 1 and 5000 characters'});
  const sourceMessageId=q.body?.sourceMessageId;
  let sourceText=text.trim(), personContext={}, conversationId;
  if(sourceMessageId!=null){
    if(typeof sourceMessageId!=='string'||!mongoose.isValidObjectId(sourceMessageId)||!mongoose.isValidObjectId(q.body?.conversationId))return r.status(400).json({error:'A valid source message and conversation are required'});
    const conversation=await Conversation.findOne({_id:q.body.conversationId,participants:q.user._id});
    if(!conversation)return r.status(403).json({error:'Conversation access required'});
    const source=await Message.findOne({_id:sourceMessageId,conversationId:conversation._id,deletedAt:{$exists:false},expiredAt:{$exists:false}});
    if(!source)return r.status(404).json({error:'Source message is unavailable'});
    // Encrypted message bodies are never sent to the server-side extractor.
    if(source.encryptionVersion===1||typeof source.text!=='string'||!source.text.trim())return r.json({candidates:[],privateMessageSkipped:true});
    if(await Memory.exists({userId:q.user._id,sourceMessageId:source._id}))return r.json({candidates:[],alreadySaved:true});
    sourceText=source.text.trim();conversationId=conversation._id;
    // Derive the person attribution from the stored sender, not client-supplied identity.
    if(String(source.senderId)!==String(q.user._id)){
      const peer=await User.findOne({_id:source.senderId,status:'active'}).select('name').lean();
      if(peer)personContext={personId:String(source.senderId),personName:peer.name};
    }
  }
  return r.json({candidates:candidate(sourceText).map(item=>({...item,...personContext,...(conversationId?{conversationId:String(conversationId)}:{})}))});
});
app.get('/api/memories',auth,async(q,r)=>{
  const limit=Math.max(1,Math.min(100,Number.parseInt(q.query.limit,10)||20));
  const filter={userId:q.user._id};
  const cursor=typeof q.query.cursor==='string'?q.query.cursor:'';
  let cursorDate,cursorId;
  if(cursor){
    try{
      const decoded=JSON.parse(Buffer.from(cursor,'base64url').toString('utf8'));
      cursorDate=new Date(decoded.createdAt);
      cursorId=String(decoded.id||'');
      if(!Number.isFinite(cursorDate.getTime())||!mongoose.isValidObjectId(cursorId))throw new Error('invalid');
    }catch{return r.status(400).json({error:'Invalid memory pagination cursor'});}
    filter.$or=[{createdAt:{$lt:cursorDate}},{createdAt:cursorDate,_id:{$lt:new O(cursorId)}}];
  }
  // Cursor reads use the compound user/time/id index and avoid deep skip scans.
  // The page parameter remains supported for older clients until they adopt nextCursor.
  if(!cursor){
    const page=Math.max(1,Math.min(10000,Number.parseInt(q.query.page,10)||1));
    if(page>1)filter.__legacyOffsetPage=page;
  }
  const legacyPage=filter.__legacyOffsetPage;
  delete filter.__legacyOffsetPage;
  const query=Memory.find(filter).sort({createdAt:-1,_id:-1}).limit(limit+1);
  if(!cursor&&legacyPage)query.skip((legacyPage-1)*limit);
  const rows=await query.lean();
  const hasMore=rows.length>limit;
  const memories=hasMore?rows.slice(0,limit):rows;
  const last=memories[memories.length-1];
  const nextCursor=hasMore&&last?Buffer.from(JSON.stringify({createdAt:last.createdAt,id:String(last._id)})).toString('base64url'):null;
  // Keep total/page fields for older app versions; clients can migrate to nextCursor.
  const [total]=await Promise.all([Memory.countDocuments({userId:q.user._id})]);
  const page=legacyPage||Math.max(1,Number.parseInt(q.query.page,10)||1);
  r.json({memories,total,page,limit,nextCursor,hasMore});
});
app.post('/api/memories',auth,async(q,r)=>{const b=q.body||{};const title=typeof b.title==='string'?b.title.trim():'';const description=typeof b.description==='string'?b.description.trim():'';if(!title||title.length>120||!description||description.length>2000||!['EVENT','PAYMENT','PLACE','TASK','NOTE','OTHER'].includes(b.type))return r.status(400).json({error:'Memory type, title and description are required'});let conversationId,sourceMessageId,personId,personName;if(b.conversationId){const c=await Conversation.findOne({_id:b.conversationId,participants:q.user._id});if(!c)return r.status(403).json({error:'Conversation access required'});conversationId=c._id;}if(b.sourceMessageId){const source=await Message.findOne({_id:b.sourceMessageId,conversationId,deletedAt:{$exists:false},expiredAt:{$exists:false}});if(!source)return r.status(400).json({error:'Source message is unavailable'});sourceMessageId=source._id;const existing=await Memory.findOne({userId:q.user._id,sourceMessageId});if(existing)return r.json({memory:existing,alreadySaved:true});if(String(source.senderId)!==String(q.user._id)&&conversationId){const peer=await User.findOne({_id:source.senderId,status:'active'}).select('name').lean();if(peer){personId=source.senderId;personName=peer.name;}}}const duplicate=await Memory.findOne({userId:q.user._id,type:b.type,title,description});if(duplicate){if(sourceMessageId&&conversationId)await MemorySuggestionSeen.updateOne({userId:q.user._id,sourceMessageId},{$set:{conversationId,status:'saved'}},{upsert:true});return r.json({memory:duplicate,alreadySaved:true});}const m=await Memory.create({userId:q.user._id,conversationId,personId,personName,sourceMessageId,type:b.type,title,description,date:b.date,time:b.time,location:b.location,completed:false});if(sourceMessageId&&conversationId)await MemorySuggestionSeen.updateOne({userId:q.user._id,sourceMessageId},{$set:{conversationId,status:'saved'}},{upsert:true});r.status(201).json({memory:m});});
app.patch('/api/memories/:id',auth,async(q,r)=>{const b=q.body||{};const allowed={};if('type'in b){if(!['EVENT','PAYMENT','PLACE','TASK','NOTE','OTHER'].includes(b.type))return r.status(400).json({error:'Unsupported memory type'});allowed.type=b.type;}for(const [key,max] of [['title',120],['description',2000],['time',80],['location',200]])if(key in b){if(typeof b[key]!=='string'||!b[key].trim()||b[key].trim().length>max)return r.status(400).json({error:`${key} must be between 1 and ${max} characters`});allowed[key]=b[key].trim();}if('date'in b){const date=b.date==null?null:new Date(b.date);if(date!=null&&Number.isNaN(date.getTime()))return r.status(400).json({error:'Enter a valid memory date'});allowed.date=date;}if('completed'in b){if(typeof b.completed!=='boolean')return r.status(400).json({error:'Completed must be true or false'});allowed.completed=b.completed;}const m=await Memory.findOneAndUpdate({_id:q.params.id,userId:q.user._id},{$set:allowed},{new:true,runValidators:true});if(!m)return r.status(404).json({error:'Memory not found'});r.json({memory:m});});
app.delete('/api/memories/:id',auth,async(q,r)=>{const memory=await Memory.findOne({_id:q.params.id,userId:q.user._id});if(memory?.sourceMessageId&&memory.conversationId)await MemorySuggestionSeen.updateOne({userId:q.user._id,sourceMessageId:memory.sourceMessageId},{$set:{conversationId:memory.conversationId,status:'deleted'}},{upsert:true});await Memory.deleteOne({_id:q.params.id,userId:q.user._id});r.status(204).end();});
// Return JSON for unknown API routes instead of Express's default HTML 404 page.
// This makes missing/stale business endpoints diagnosable by the Flutter client.
app.use((q,r,n)=>{
  if(q.path.startsWith('/api/')) {
    return r.status(404).json({
      error:'API endpoint not found. Confirm the backend deployment is running the latest main branch.',
      path:q.path,
    });
  }
  return n();
});
// Centralized error handler: keep all API failures in a predictable JSON format.
app.use((err,q,r,n)=>{if(r.headersSent)return n(err);const status=err.code===11000?409:err.status||err.statusCode||(['ValidationError','CastError'].includes(err.name)?400:500);const message=status===409?'A record with that value already exists':status<500?(err.message||'Request failed'):'Request failed';r.status(status).json({error:message});});
// PERIODIC EXPIRY JOB: clears/hides due message content and broadcasts an expiry event.
let notificationWorkerRunning=false;
const notificationTimer=setInterval(async()=>{
  if(notificationWorkerRunning||mongoose.connection.readyState!==1)return;
  notificationWorkerRunning=true;
  try{
    // Atomic claims allow multiple replicas to share the queue; leases recover crashed workers.
    for(let i=0;i<20;i++){
      const now=new Date();
      const job=await NotificationJob.findOneAndUpdate(
        {status:{$in:['queued','processing']},availableAt:{$lte:now},$or:[{lockedUntil:{$exists:false}},{lockedUntil:{$lte:now}}]},
        {$set:{status:'processing',lockedUntil:new Date(now.getTime()+60000)},$inc:{attempts:1}},
        {new:true,sort:{availableAt:1,createdAt:1}}
      ).lean();
      if(!job)break;
      try{
        const recipient=await User.findById(job.recipientId).select('notificationPreferences pushTokens').lean();
        if(!recipient||recipient.notificationPreferences?.messages===false||!recipient.pushTokens?.length){
          await NotificationJob.updateOne({_id:job._id,status:'processing'},{$set:{status:'done',completedAt:new Date(),expireAt:notificationExpiryDate()},$unset:{lockedUntil:1}});
          continue;
        }
        const results=await Promise.allSettled(recipient.pushTokens.map(token=>notificationProvider.send({token,messageId:String(job.messageId),conversationId:String(job.conversationId),type:'message'})));
        const invalid=recipient.pushTokens.filter((token,j)=>results[j].status==='rejected'&&['messaging/invalid-registration-token','messaging/registration-token-not-registered'].includes(results[j].reason?.code));
        if(invalid.length)await User.updateOne({_id:recipient._id},{$pull:{pushTokens:{$in:invalid}}});
        const failures=results.filter(result=>result.status==='rejected'&&!['messaging/invalid-registration-token','messaging/registration-token-not-registered'].includes(result.reason?.code));
        if(failures.length)throw failures[0].reason;
        await NotificationJob.updateOne({_id:job._id,status:'processing'},{$set:{status:'done',completedAt:new Date(),expireAt:notificationExpiryDate()},$unset:{lockedUntil:1,lastError:1}});
      }catch(error){
        const attempts=Number(job.attempts)||1,terminal=attempts>=MAX_NOTIFICATION_ATTEMPTS;
        await NotificationJob.updateOne({_id:job._id,status:'processing'},{$set:{status:terminal?'failed':'queued',availableAt:new Date(Date.now()+notificationRetryDelayMs(attempts)),...(terminal?{expireAt:notificationExpiryDate()}:{}),lastError:String(error?.message||'Notification delivery failed').slice(0,180)},$unset:{lockedUntil:1}}).catch(()=>{});
        console.error('Notification job delivery failed',{jobId:String(job._id),attempt:attempts,terminal});
      }
    }
  }catch(error){console.error('Notification worker tick failed',error.message);}
  finally{notificationWorkerRunning=false;}
},1000);
notificationTimer.unref();

let expirySweepRunning=false;
const expiryTimer=setInterval(async()=>{
  // Bound each sweep so a backlog cannot monopolize the API event loop or load all due
  // records into memory. Atomic conditional updates make competing replicas safe.
  if(expirySweepRunning||mongoose.connection.readyState!==1)return;
  expirySweepRunning=true;
  try{
    const due=await Message.find({expiresAt:{$lte:new Date()},expiredAt:{$exists:false}})
      .sort({expiresAt:1,_id:1}).limit(250).select('_id conversationId').lean();
    for(const item of due){
      const expiredAt=new Date();
      const expired=await Message.findOneAndUpdate({_id:item._id,expiredAt:{$exists:false},expiresAt:{$lte:expiredAt}},
        {$set:{expiredAt,text:'',encryptedPayload:null,mediaUrl:null}},{new:true}).select('_id').lean();
      if(expired)io.to(String(item.conversationId)).emit('message:expired',{messageId:item._id});
    }
  }catch(error){console.error('Message expiration cleanup failed:',error.message);}
  finally{expirySweepRunning=false;}
},60000);
expiryTimer.unref();
if(env.mongo)await mongoose.connect(env.mongo,{
  // Keep pool usage predictable as API replicas scale out. Budget total connections as
  // (maxPoolSize × API replicas) plus workers and operational headroom against Atlas limits.
  maxPoolSize:Number.parseInt(process.env.MONGO_MAX_POOL_SIZE||'30',10),
  minPoolSize:Number.parseInt(process.env.MONGO_MIN_POOL_SIZE||'2',10),
  maxIdleTimeMS:30000,
  serverSelectionTimeoutMS:10000,
  socketTimeoutMS:45000,
  autoIndex:process.env.MONGO_AUTO_INDEX==='true'
}); else console.warn('MONGODB_URI not set; configure Atlas before persistent use.');
server.listen(env.port,()=>console.log('Chatify API listening on '+env.port));
// GRACEFUL SHUTDOWN: stop timers and close network/database resources as the process exits.
const shutdown=createShutdownHandler({
  stopTimers:()=>{clearInterval(expiryTimer);clearInterval(notificationTimer);},
  closeSockets:()=>new Promise(resolve=>io.close(resolve)),
  closeHttp:()=>new Promise((resolve,reject)=>{
    if(!server.listening)return resolve();
    server.close(error=>error?reject(error):resolve());
  }),
  disconnectDb:()=>mongoose.disconnect(),
});
for(const signal of ['SIGINT','SIGTERM'])process.once(signal,()=>{
  shutdown().then(()=>{console.log('Chatify API shut down cleanly.');},()=>{
    console.error('Chatify API shutdown failed.');
    process.exitCode=1;
  });
});
export {app,candidate};
