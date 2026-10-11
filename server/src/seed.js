import 'dotenv/config';
import mongoose from 'mongoose';
import bcrypt from 'bcryptjs';
import {resolveDemoSeedConfig} from './seedConfig.js';

const {uri, passwordValue} = resolveDemoSeedConfig(process.env);
const O = mongoose.Schema.Types.ObjectId;
const User = mongoose.model('User', new mongoose.Schema({
  name: String,
  email: {type: String, unique: true},
  passwordHash: String,
  status: {type: String, default: 'active'},
}, {timestamps: true}));
const Conversation = mongoose.model('Conversation', new mongoose.Schema({
  type: String,
  participants: [O],
  title: String,
  admins: [O],
  lastMessage: {text: String, senderId: O, createdAt: Date},
}, {timestamps: true}));
const Message = mongoose.model('Message', new mongoose.Schema({
  conversationId: O,
  senderId: O,
  text: String,
  expiryType: String,
  readBy: [O],
}, {timestamps: true}));
const Memory = mongoose.model('Memory', new mongoose.Schema({
  userId: O,
  conversationId: O,
  type: String,
  title: String,
  description: String,
  location: String,
  sourceMessageId: O,
  completed: Boolean,
}, {timestamps: true}));

await mongoose.connect(uri);
try {
  const passwordHash = await bcrypt.hash(passwordValue, 12);
  const alice = await User.findOneAndUpdate(
    {email: 'alice@chatify.demo'},
    {name: 'Alice', email: 'alice@chatify.demo', passwordHash},
    {upsert: true, new: true},
  );
  const brian = await User.findOneAndUpdate(
    {email: 'brian@chatify.demo'},
    {name: 'Brian', email: 'brian@chatify.demo', passwordHash},
    {upsert: true, new: true},
  );
  let conversation = await Conversation.findOne({
    type: 'direct',
    participants: {$all: [alice._id, brian._id], $size: 2},
  });
  if (!conversation) {
    conversation = await Conversation.create({
      type: 'direct', participants: [alice._id, brian._id],
    });
  }
  let message = await Message.findOne({
    conversationId: conversation._id,
    senderId: alice._id,
    text: /library/,
  });
  if (!message) {
    message = await Message.create({
      conversationId: conversation._id,
      senderId: alice._id,
      text: "Let's meet at the library tomorrow at 2 PM to discuss the project.",
      expiryType: 'NONE',
      readBy: [alice._id],
    });
  }
  await Memory.findOneAndUpdate(
    {userId: alice._id, title: 'Project Meeting'},
    {
      userId: alice._id,
      conversationId: conversation._id,
      type: 'EVENT',
      title: 'Project Meeting',
      description: 'Discuss the project',
      time: '2 PM',
      location: 'Library',
      sourceMessageId: message._id,
      completed: false,
    },
    {upsert: true},
  );
  console.log('Demo seed ready: Alice/Brian, one conversation, message and memory.');
} finally {
  await mongoose.disconnect();
}
