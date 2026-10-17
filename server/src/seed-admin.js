import 'dotenv/config';
import mongoose from 'mongoose';
import bcrypt from 'bcryptjs';

// Create or promote exactly the administrator account explicitly configured by the
// deployment environment. Never ship a hard-coded production email or password.
const uri = process.env.MONGODB_URI?.trim();
const email = process.env.ADMIN_EMAIL?.trim().toLowerCase();
const password = process.env.ADMIN_PASSWORD;
const name = (process.env.ADMIN_NAME || 'Chatify Administrator').trim();

if (!uri) throw new Error('MONGODB_URI is required to seed the administrator.');
if (!email || !/^\S+@\S+\.\S+$/.test(email)) {
  throw new Error('Set ADMIN_EMAIL to the intended administrator email address.');
}
if (typeof password !== 'string' || Buffer.byteLength(password, 'utf8') < 12 ||
    Buffer.byteLength(password, 'utf8') > 72) {
  throw new Error('ADMIN_PASSWORD must be 12–72 UTF-8 bytes; do not use a default password.');
}
if (!name || name.length > 80) throw new Error('ADMIN_NAME must be 1–80 characters.');

const O = mongoose.Schema.Types.ObjectId;
const User = mongoose.models.User || mongoose.model('User', new mongoose.Schema({
  name: {type: String, required: true, trim: true, maxlength: 80},
  email: {type: String, unique: true, lowercase: true, trim: true, required: true},
  phone: String,
  passwordHash: {type: String, required: true},
  emailVerified: {type: Boolean, default: true},
  emailVerificationTokenHash: String,
  emailVerificationExpiresAt: Date,
  profileImage: String,
  status: {type: String, default: 'active'},
  role: {type: String, enum: ['user', 'admin'], default: 'user', index: true},
  lastSeen: Date,
  privacy: {lastSeen: {type: Boolean, default: true}, readReceipts: {type: Boolean, default: true}},
  blockedUsers: [O],
  pushTokens: {type: [String], default: []},
  notificationPreferences: {
    messages: {type: Boolean, default: true},
    mentions: {type: Boolean, default: true},
    memories: {type: Boolean, default: true},
  },
}, {timestamps: true}));

await mongoose.connect(uri);
try {
  const passwordHash = await bcrypt.hash(password, 12);
  const user = await User.findOneAndUpdate(
    {email},
    {$set: {
      name,
      email,
      passwordHash,
      role: 'admin',
      status: 'active',
      emailVerified: true,
    }, $unset: {emailVerificationTokenHash: 1, emailVerificationExpiresAt: 1}},
    {upsert: true, new: true, runValidators: true, setDefaultsOnInsert: true},
  );
  console.log('Administrator account is ready:', user.email);
  console.log('Sign in using the configured credentials, then open the Admin tab.');
} finally {
  await mongoose.disconnect();
}
