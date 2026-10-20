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
    collection:'memories',
    keys:{userId:1,createdAt:-1,_id:-1},
    options:{name:'user_memory_history_cursor_v1'},
  },
  {
    collection:'conversations',
    keys:{participants:1,updatedAt:-1,_id:-1},
    options:{name:'participant_recent_conversations_v1'},
  },
];

try{
  await mongoose.connect(uri,options);
  for(const index of indexes){
    await mongoose.connection.collection(index.collection).createIndex(index.keys,index.options);
    console.log('Ensured index',index.collection,index.options.name);
  }
  console.log('Index migration complete. No existing indexes or records were removed.');
}catch(error){
  console.error('Index migration failed:',error.message);
  process.exitCode=1;
}finally{
  await mongoose.disconnect();
}
