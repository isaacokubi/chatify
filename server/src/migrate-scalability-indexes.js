// Explicit, non-destructive index migration for Chatify's highest-volume query paths.
// Run from server/ with MONGODB_URI set after reviewing the target database.
// This script creates indexes only; it never drops collections, records, or existing indexes.
import 'dotenv/config';
import mongoose from 'mongoose';

const uri=process.env.MONGODB_URI?.trim();
if(!uri)throw new Error('MONGODB_URI is required to run the index migration');

const options={
  maxPoolSize:2,
  minPoolSize:0,
  serverSelectionTimeoutMS:10000,
  socketTimeoutMS:45000,
  autoIndex:false,
};

const indexes=[
  {
    collection:'messages',
    keys:{conversationId:1,createdAt:-1,_id:-1},
    options:{name:'conversation_history_cursor_v1'},
  },
  {
    collection:'messages',
    keys:{expiresAt:1,expiredAt:1,conversationId:1},
    options:{name:'message_expiry_sweep_v1'},
  },
  {
    collection:'messages',
    keys:{senderId:1,clientMutationId:1},
    options:{name:'message_sender_mutation_unique_v1',unique:true,partialFilterExpression:{clientMutationId:{$type:'string'}}},
  },
  {
    collection:'memories',
    keys:{userId:1,createdAt:-1,_id:-1},
    options:{name:'user_memory_history_cursor_v1'},
  },
  {
    collection:'notificationjobs',
    keys:{recipientId:1,messageId:1},
    options:{name:'notification_job_dedupe_v1',unique:true},
  },
  {
    collection:'notificationjobs',
    keys:{status:1,availableAt:1,lockedUntil:1,createdAt:1},
    options:{name:'notification_jobs_claim_v1'},
  },
  {
    collection:'notificationjobs',
    keys:{expireAt:1},
    options:{name:'notification_jobs_ttl_v1',expireAfterSeconds:0,partialFilterExpression:{expireAt:{$type:'date'}}},
  },
  {
    collection:'conversations',
    keys:{participants:1,updatedAt:-1,_id:-1},
    options:{name:'participant_recent_conversations_v1'},
  },
  {
    collection:'sparks',
    keys:{authorId:1,createdAt:-1,expiresAt:1},
    options:{name:'spark_feed_author_created_expiry_v1'},
  },
  {
    collection:'payments',
    keys:{providerReceipt:1},
    options:{name:'payment_provider_receipt_unique_v1',unique:true,sparse:true},
  },
  {
    collection:'payments',
    keys:{requesterId:1,billingWorkspaceType:1,billingWorkspaceId:1,billingType:1},
    options:{name:'workspace_billing_pending_unique_v1',unique:true,partialFilterExpression:{status:'PENDING',billingWorkspaceId:{$type:'objectId'},billingType:{$type:'string'}}},
  },
];

// Check all unique-index candidates before creating any indexes. This avoids leaving a
// half-applied migration when older data contains duplicate provider receipts or IDs.
// The report includes only duplicate key values and counts needed for manual cleanup.
const uniquePreflights=[
  {collection:'messages',name:'message_sender_mutation_unique_v1',match:{clientMutationId:{$type:'string'}},keys:{senderId:'$senderId',clientMutationId:'$clientMutationId'}},
  // The non-sparse notification index also indexes missing fields as null, so the
  // preflight must include every document to mirror MongoDB's actual uniqueness rules.
  {collection:'notificationjobs',name:'notification_job_dedupe_v1',match:{},keys:{recipientId:'$recipientId',messageId:'$messageId'}},
  // A sparse index includes explicit nulls; only documents missing the field entirely are excluded.
  {collection:'payments',name:'payment_provider_receipt_unique_v1',match:{providerReceipt:{$exists:true}},keys:{providerReceipt:'$providerReceipt'}},
  {collection:'payments',name:'workspace_billing_pending_unique_v1',match:{status:'PENDING',billingWorkspaceId:{$type:'objectId'},billingType:{$type:'string'}},keys:{requesterId:'$requesterId',billingWorkspaceType:'$billingWorkspaceType',billingWorkspaceId:'$billingWorkspaceId',billingType:'$billingType'}},
];

async function preflightUniqueIndexes(){
  const conflicts=[];
  for(const index of uniquePreflights){
    const duplicates=await mongoose.connection.collection(index.collection).aggregate([
      {$match:index.match},
      {$group:{_id:index.keys,count:{$sum:1}}},
      {$match:{count:{$gt:1}}},
      {$limit:6},
    ]).toArray();
    if(duplicates.length){
      conflicts.push({index:index.name,collection:index.collection,examples:duplicates.map(row=>({key:row._id,count:row.count}))});
    }
  }
  if(conflicts.length){
    const error=new Error('Unique-index preflight found duplicate existing data. No indexes were created; resolve these records and rerun.');
    error.conflicts=conflicts;
    throw error;
  }
}

try{
  await mongoose.connect(uri,options);
  await preflightUniqueIndexes();
  for(const index of indexes){
    await mongoose.connection.collection(index.collection).createIndex(index.keys,index.options);
    console.log('Ensured index',index.collection,index.options.name);
  }
  console.log('Index migration complete. No existing indexes or records were removed.');
}catch(error){
  console.error('Index migration failed:',error.message);
  if(Array.isArray(error.conflicts)) console.error(JSON.stringify(error.conflicts,null,2));
  process.exitCode=1;
}finally{
  await mongoose.disconnect();
}
