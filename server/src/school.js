// School communication, conferences and fee-ledger API.
// All school records are scoped to the authenticated user's school membership.
// A fee receipt is available only after an authorized staff member verifies payment.
import { randomUUID, randomBytes, createCipheriv, createDecipheriv, createHash } from 'node:crypto';
import { createDarajaProvider, normalizeMpesaPhone, resolveCallbackOutcome } from './payments.js';

export function encryptSchoolSecret(value, secret = process.env.SCHOOL_PAYMENT_ENCRYPTION_KEY) {
  if (typeof secret !== 'string' || secret.trim().length < 32) throw new Error('School payment encryption is not configured');
  const key = createHash('sha256').update(secret).digest();
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(String(value), 'utf8'), cipher.final()]);
  return [iv.toString('hex'), cipher.getAuthTag().toString('hex'), encrypted.toString('hex')].join(':');
}

export function decryptSchoolSecret(value, secret = process.env.SCHOOL_PAYMENT_ENCRYPTION_KEY) {
  if (typeof value !== 'string' || !value || typeof secret !== 'string' || secret.trim().length < 32) throw new Error('School payment credentials or encryption key are not configured');
  const [iv, tag, encrypted] = value.split(':');
  if (!iv || !tag || !encrypted) throw new Error('Stored school payment credentials are invalid');
  const decipher = createDecipheriv('aes-256-gcm', createHash('sha256').update(secret).digest(), Buffer.from(iv, 'hex'));
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  return Buffer.concat([decipher.update(Buffer.from(encrypted, 'hex')), decipher.final()]).toString('utf8');
}

function escapeReceipt(value) {
  return String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
}

function renderSchoolReceipt(school, payment) {
  const esc = escapeReceipt;
  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>School fee receipt</title><style>body{font:16px system-ui,sans-serif;max-width:720px;margin:32px auto;padding:24px;color:#172033}main{border:1px solid #ccd3df;border-radius:16px;padding:28px}h1{margin-top:0}dt{font-weight:700;margin-top:14px}dd{margin:4px 0}button{padding:10px 16px}@media print{button{display:none}body{margin:0}}</style></head><body><main><h1>' + esc(school?.name || 'School') + '</h1><h2>Official school fee receipt</h2><p>Payment confirmation recorded by the school.</p><dl><dt>Receipt number</dt><dd>' + esc(payment.mpesaReceipt) + '</dd><dt>Chatify reference</dt><dd>' + esc(payment.paymentReference) + '</dd><dt>Student</dt><dd>' + esc(payment.studentName) + '</dd><dt>Term</dt><dd>' + esc(payment.term) + '</dd><dt>Amount received</dt><dd>KSh ' + esc(Number(payment.amount).toLocaleString('en-KE')) + '</dd><dt>Verified on</dt><dd>' + esc(payment.verifiedAt?.toISOString?.() || '') + '</dd></dl><button onclick="window.print()">Print receipt</button></main></body></html>';
}

function schoolCallbackUrl() {
  const base = String(process.env.PUBLIC_API_URL || process.env.API_URL || '').trim();
  if (!base) throw new Error('Set PUBLIC_API_URL or API_URL to the public HTTPS API URL before enabling school M-Pesa');
  const url = new URL('/api/schools/daraja/callback', base.replace(/\/$/, ''));
  if (url.protocol !== 'https:') throw new Error('School M-Pesa callback URL must be public HTTPS');
  return url.toString();
}

function providerForSchool(school) {
  const profile = school?.paymentProfile;
  if (!profile?.darajaConsumerKeyEnc || !profile?.darajaConsumerSecretEnc || !profile?.darajaPasskeyEnc) throw new Error('This school has not configured its own Daraja credentials.');
  const mode = profile.darajaMode || 'production';
  if (process.env.NODE_ENV === 'production' && mode !== 'production') throw new Error('Production school payments require live Daraja credentials; sandbox STK Push is blocked.');
  return createDarajaProvider({
    mode,
    consumerKey: decryptSchoolSecret(profile.darajaConsumerKeyEnc),
    consumerSecret: decryptSchoolSecret(profile.darajaConsumerSecretEnc),
    shortcode: profile.method === 'mpesa_paybill' ? profile.paybillNumber : profile.tillNumber,
    passkey: decryptSchoolSecret(profile.darajaPasskeyEnc),
    callbackUrl: schoolCallbackUrl(),
    transactionType: profile.method === 'mpesa_till' ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline',
  });
}

export function normalizeSchoolPaymentProfile(input = {}) {
  const method = ['mpesa_paybill', 'mpesa_till', 'bank'].includes(input.method) ? input.method : null;
  if (!method) throw new Error('Choose M-Pesa Paybill, M-Pesa Till or bank transfer');
  const paybillNumber = String(input.paybillNumber || '').trim().replace(/\s+/g, '');
  const tillNumber = String(input.tillNumber || '').trim().replace(/\s+/g, '');
  const accountNumber = String(input.accountNumber || '').trim().slice(0, 80);
  const bankName = String(input.bankName || '').trim().slice(0, 100);
  if (method === 'mpesa_paybill' && !/^\d{5,10}$/.test(paybillNumber)) throw new Error('Enter a valid school Paybill number');
  if (method === 'mpesa_till' && !/^\d{5,10}$/.test(tillNumber)) throw new Error('Enter a valid school Till number');
  if (method === 'bank' && (!bankName || !accountNumber)) throw new Error('Enter the school bank name and account number');
  return { method, paybillNumber: method === 'mpesa_paybill' ? paybillNumber : '', tillNumber: method === 'mpesa_till' ? tillNumber : '', accountNumber, bankName };
}

export function registerSchoolRoutes({ app, auth, mongoose, User, emailProvider }) {
  const O = mongoose.Schema.Types.ObjectId;
  const model = (name, schema) => mongoose.models[name] || mongoose.model(name, schema);
  const School = model('SchoolWorkspace', new mongoose.Schema({
    name: { type: String, required: true, trim: true, maxlength: 160 },
    code: { type: String, required: true, trim: true, uppercase: true, maxlength: 24 },
    staffInviteCode: { type: String, default: () => randomUUID().replace(/-/g, '').slice(0, 16).toUpperCase(), select: false },
    createdBy: { type: O, ref: 'User', required: true },
    paymentProfile: {
      method: { type: String, enum: ['mpesa_paybill','mpesa_till','bank'] },
      paybillNumber: String, tillNumber: String, accountNumber: String, bankName: String,
      darajaMode: { type: String, enum: ['sandbox','production'] },
      darajaConsumerKeyEnc: { type: String, select: false },
      darajaConsumerSecretEnc: { type: String, select: false },
      darajaPasskeyEnc: { type: String, select: false },
      darajaConfiguredAt: Date,
    },
  }, { timestamps: true }));
  School.schema.index({ code: 1 }, { unique: true });
  const Membership = model('SchoolMembership', new mongoose.Schema({
    schoolId: { type: O, ref: 'SchoolWorkspace', required: true, index: true },
    userId: { type: O, ref: 'User', required: true, index: true },
    role: { type: String, enum: ['admin','staff','parent'], required: true },
    studentNames: { type: [String], default: [] },
    active: { type: Boolean, default: true },
  }, { timestamps: true }));
  Membership.schema.index({ schoolId: 1, userId: 1 }, { unique: true });
  const SchoolMessage = model('SchoolMessage', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    senderId: { type: O, required: true },
    recipientId: { type: O, index: true },
    audience: { type: String, enum: ['direct','all_parents','all_staff','all_school'], default: 'direct' },
    subject: { type: String, trim: true, maxlength: 160 },
    body: { type: String, required: true, trim: true, maxlength: 5000 },
  }, { timestamps: true }));
  const SchoolConference = model('SchoolConference', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    createdBy: { type: O, required: true },
    title: { type: String, required: true, trim: true, maxlength: 160 },
    agenda: { type: String, required: true, trim: true, maxlength: 5000 },
    startsAt: { type: Date, required: true },
    endsAt: { type: Date, required: true },
    audience: { type: String, enum: ['all_parents','all_staff','all_school'], default: 'all_parents' },
    location: { type: String, trim: true, maxlength: 300 },
    meetingUrl: { type: String, trim: true, maxlength: 1000 },
  }, { timestamps: true }));
  const FeePayment = model('SchoolFeePayment', new mongoose.Schema({
    paymentReference: { type: String, required: true, unique: true, index: true },
    schoolId: { type: O, required: true, index: true },
    parentId: { type: O, required: true, index: true },
    studentName: { type: String, required: true, trim: true, maxlength: 100 },
    amount: { type: Number, required: true, min: 1, max: 150000 },
    term: { type: String, required: true, trim: true, maxlength: 80 },
    status: { type: String, enum: ['PENDING_STK','PENDING_VERIFICATION','CONFIRMED','FAILED','CANCELLED','REJECTED'], default: 'PENDING_VERIFICATION', index: true },
    payerPhone: { type: String, trim: true },
    checkoutRequestId: { type: String, sparse: true, index: true },
    merchantRequestId: { type: String },
    callbackProcessedAt: Date,
    receiptHtml: { type: String, select: false },
    receiptEmailSentTo: { type: [String], default: [] },
    receiptEmailLastError: String,
    mpesaReceipt: { type: String, trim: true, uppercase: true, maxlength: 40 },
    verifiedBy: O,
    verifiedAt: Date,
  }, { timestamps: true }));
  FeePayment.schema.index({ schoolId: 1, mpesaReceipt: 1 }, { unique: true, sparse: true });
  FeePayment.schema.index({ checkoutRequestId: 1, merchantRequestId: 1 }, { unique: true, sparse: true });

  // Bounded server-side pagination for every school register.
  function pageOptions(req) {
    const page = Math.max(1, Math.min(100000, Number.parseInt(req.query.page, 10) || 1));
    const limit = Math.max(1, Math.min(100, Number.parseInt(req.query.limit, 10) || 20));
    return { page, limit, skip: (page - 1) * limit };
  }

  async function membership(req, schoolId) {
    if (!mongoose.isValidObjectId(schoolId)) return null;
    return Membership.findOne({ schoolId, userId: req.user._id, active: true });
  }
  const requireRole = (...roles) => async (req, res, next) => {
    try {
      const schoolId = req.params.schoolId || req.params.id;
      const member = await membership(req, schoolId);
      if (!member) return res.status(403).json({ error: 'You are not a member of this school' });
      if (!roles.includes(member.role)) return res.status(403).json({ error: 'Your school role cannot perform this action' });
      // A role value alone must never grant control of another person's workspace.
      // Only the account that created the school may use administrator-only actions.
      if (member.role === 'admin' && roles.includes('admin')) {
        const ownsSchool = await School.exists({ _id: schoolId, createdBy: req.user._id });
        if (!ownsSchool) return res.status(403).json({ error: 'Only the school workspace owner can change school settings or administer this workspace.' });
      }
      req.schoolMembership = member;
      return next();
    } catch (error) { return next(error); }
  };

  app.post('/api/schools', auth, async (req, res, next) => {
    try {
      const name = String(req.body?.name || '').trim();
      const code = String(req.body?.code || '').trim().toUpperCase();
      if (!name || name.length > 160 || !/^[A-Z0-9-]{3,24}$/.test(code)) return res.status(400).json({ error: 'Enter a school name and a unique 3–24 character code using letters, numbers or hyphens' });
      const school = await School.create({ name, code, createdBy: req.user._id });
      await Membership.create({ schoolId: school._id, userId: req.user._id, role: 'admin' });
      return res.status(201).json({ school: { id: String(school._id), name: school.name, code: school.code, staffInviteCode: school.staffInviteCode }, role: 'admin' });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'That school code is already in use' });
      return next(error);
    }
  });

  app.get('/api/schools', auth, async (req, res, next) => {
    try {
      const memberships = await Membership.find({ userId: req.user._id, active: true }).lean();
      const ids = memberships.map(m => m.schoolId);
      const schools = await School.find({ _id: { $in: ids } }).select('+staffInviteCode name code createdBy paymentProfile.method paymentProfile.paybillNumber paymentProfile.tillNumber paymentProfile.accountNumber paymentProfile.bankName paymentProfile.darajaMode paymentProfile.darajaConfiguredAt').lean();
      // Older workspaces created before staff invitation codes existed receive one lazily
      // when an administrator opens the workspace; only admins ever receive it in responses.
      for (const school of schools) {
        const member = memberships.find(m => String(m.schoolId) === String(school._id));
        if (member?.role === 'admin' && !school.staffInviteCode) {
          const generated = randomUUID().replace(/-/g, '').slice(0, 16).toUpperCase();
          const updated = await School.findOneAndUpdate(
            { _id: school._id, $or: [{ staffInviteCode: { $exists: false } }, { staffInviteCode: null }] },
            { $set: { staffInviteCode: generated } },
            { new: true }
          ).select('+staffInviteCode').lean();
          school.staffInviteCode = updated?.staffInviteCode || generated;
        }
      }
      return res.json({ schools: schools.map(s => ({ id: String(s._id), name: s.name, code: s.code, role: memberships.find(m => String(m.schoolId) === String(s._id))?.role, isOwner: String(s.createdBy) === String(req.user._id), staffInviteCode: memberships.find(m => String(m.schoolId) === String(s._id))?.role === 'admin' ? s.staffInviteCode : undefined, paymentProfile: s.paymentProfile?.method ? { method: s.paymentProfile.method, paybillNumber: s.paymentProfile.paybillNumber, tillNumber: s.paymentProfile.tillNumber, accountNumber: s.paymentProfile.accountNumber, bankName: s.paymentProfile.bankName, darajaMode: s.paymentProfile.darajaMode, darajaConfigured: Boolean(s.paymentProfile.darajaConfiguredAt) } : null })) });
    } catch (error) { return next(error); }
  });

  // Authenticated parents and staff may join using the school's invite code. The role is
  // restricted to parent/staff; school administrator privileges can never be self-assigned.
  app.post('/api/schools/join', auth, async (req, res, next) => {
    try {
      const code = String(req.body?.code || '').trim().toUpperCase();
      const role = String(req.body?.role || '');
      const studentNames = Array.isArray(req.body?.studentNames)
        ? [...new Set(req.body.studentNames.map(x => String(x).trim()).filter(Boolean))].slice(0, 10)
        : [];
      if (!code || code.length > 40 || !['parent', 'staff'].includes(role)) {
        return res.status(400).json({ error: 'Enter the school invite code and choose Parent or Staff.' });
      }
      if (role === 'parent' && studentNames.length === 0) {
        return res.status(400).json({ error: 'Parents must enter at least one linked student name. Ask the school office to add the exact student name if unsure.' });
      }
      const school = await School.findOne({ code }).select('+staffInviteCode _id name code').lean();
      if (!school) return res.status(404).json({ error: 'No school was found for that code. Check the code with the school office.' });
      if (String(school.createdBy) === String(req.user._id)) {
        return res.status(409).json({ error: 'You own this school workspace already. Select it from Your school instead of joining it again.' });
      }
      if (role === 'staff' && (!school.staffInviteCode || String(req.body?.staffInviteCode || '').trim().toUpperCase() !== school.staffInviteCode)) {
        return res.status(403).json({ error: 'A separate staff invitation code is required. Request it from the school administrator.' });
      }
      const member = await Membership.findOneAndUpdate(
        { schoolId: school._id, userId: req.user._id },
        { $set: { role, studentNames, active: true } },
        { upsert: true, new: true, runValidators: true }
      );
      return res.status(200).json({ school: { id: String(school._id), name: school.name, code: school.code }, member: { id: String(member._id), role: member.role, studentNames: member.studentNames } });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/members', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const email = String(req.body?.email || '').trim().toLowerCase();
      const role = String(req.body?.role || '');
      const studentNames = Array.isArray(req.body?.studentNames) ? req.body.studentNames.map(x => String(x).trim()).filter(Boolean).slice(0, 10) : [];
      if (!/^\S+@\S+\.\S+$/.test(email) || !['staff','parent'].includes(role)) return res.status(400).json({ error: 'Enter a valid existing account email and choose staff or parent' });
      const user = await User.findOne({ email }).select('_id name email');
      if (!user) return res.status(404).json({ error: 'Create or invite the user to Chatify before adding them to this school' });
      const member = await Membership.findOneAndUpdate({ schoolId: req.params.schoolId, userId: user._id }, { $set: { role, studentNames, active: true } }, { upsert: true, new: true, runValidators: true });
      return res.status(200).json({ member: { id: String(member._id), userId: String(user._id), name: user.name, email: user.email, role: member.role, studentNames: member.studentNames } });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/members', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const page = pageOptions(req);
      const filter = { schoolId: req.params.schoolId, active: true };
      if (req.schoolMembership.role === 'parent') filter.role = { $in: ['admin','staff'] };
      const [rows, total] = await Promise.all([
        Membership.find(filter).sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).populate('userId', 'name email').lean(),
        Membership.countDocuments(filter),
      ]);
      return res.json({ members: rows.filter(x => x.userId).map(x => ({ id: String(x._id), userId: String(x.userId._id), name: x.userId.name, email: x.userId.email, role: x.role, studentNames: x.studentNames })), total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  // School admins can correct the pupil names a parent linked during workspace joining.
  // This updates only that parent's school membership, not the parent's Chatify account.
  app.put('/api/schools/:schoolId/members/:memberId/student-info', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const rawNames = req.body?.studentNames;
      if (!Array.isArray(rawNames) || rawNames.length === 0 || rawNames.length > 10) {
        return res.status(400).json({ error: 'Enter between 1 and 10 linked student names.' });
      }
      const studentNames = [...new Set(rawNames.map(value => String(value ?? '').trim()).filter(Boolean))];
      if (studentNames.length === 0 || studentNames.some(name => name.length > 100)) {
        return res.status(400).json({ error: 'Each linked student name must contain 1–100 characters.' });
      }
      if (!mongoose.isValidObjectId(req.params.memberId)) {
        return res.status(400).json({ error: 'Invalid school member.' });
      }
      const member = await Membership.findOneAndUpdate(
        { _id: req.params.memberId, schoolId: req.params.schoolId, role: 'parent', active: true },
        { $set: { studentNames } },
        { new: true, runValidators: true }
      ).populate('userId', 'name email');
      if (!member) return res.status(404).json({ error: 'Active parent membership was not found in this school.' });
      return res.json({
        member: {
          id: String(member._id),
          userId: String(member.userId?._id || member.userId),
          name: member.userId?.name,
          email: member.userId?.email,
          role: member.role,
          studentNames: member.studentNames,
        },
        message: 'Linked pupil information updated.',
      });
    } catch (error) { return next(error); }
  });

  app.put('/api/schools/:schoolId/payment-profile', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const profile = normalizeSchoolPaymentProfile(req.body || {});
      const update = { ...profile };
      if (profile.method !== 'bank') {
        const mode = String(req.body?.darajaMode || (process.env.NODE_ENV === 'production' ? 'production' : 'sandbox'));
        if (!['sandbox','production'].includes(mode)) return res.status(400).json({ error: 'Choose sandbox or production Daraja environment' });
        if (process.env.NODE_ENV === 'production' && mode !== 'production') return res.status(400).json({ error: 'Sandbox is disabled for production school payments' });
        const consumerKey = String(req.body?.darajaConsumerKey || '').trim();
        const consumerSecret = String(req.body?.darajaConsumerSecret || '').trim();
        const passkey = String(req.body?.darajaPasskey || '').trim();
        if (!consumerKey || !consumerSecret || !passkey) return res.status(400).json({ error: 'Enter this school’s Daraja consumer key, consumer secret and shortcode passkey. These are encrypted before storage.' });
        const callbackUrl = schoolCallbackUrl();
        createDarajaProvider({ mode, consumerKey, consumerSecret, shortcode: profile.method === 'mpesa_paybill' ? profile.paybillNumber : profile.tillNumber, passkey, callbackUrl, transactionType: profile.method === 'mpesa_till' ? 'CustomerBuyGoodsOnline' : 'CustomerPayBillOnline' });
        update.darajaMode = mode;
        update.darajaConsumerKeyEnc = encryptSchoolSecret(consumerKey);
        update.darajaConsumerSecretEnc = encryptSchoolSecret(consumerSecret);
        update.darajaPasskeyEnc = encryptSchoolSecret(passkey);
        update.darajaConfiguredAt = new Date();
      }
      await School.updateOne({ _id: req.params.schoolId }, { $set: { paymentProfile: update } });
      return res.json({ paymentProfile: { ...profile, darajaConfigured: profile.method !== 'bank' && Boolean(update.darajaConfiguredAt), darajaMode: update.darajaMode || null }, note: profile.method === 'bank' ? 'Bank destination saved. Bank payments require school staff verification.' : 'School-specific Daraja credentials encrypted and saved. M-Pesa STK Push is enabled for this school.' });
    } catch (error) { if (error instanceof Error && !error.name.startsWith('Mongo')) return res.status(400).json({ error: error.message }); return next(error); }
  });

  app.post('/api/schools/:schoolId/messages', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const body = String(req.body?.body || '').trim();
      const audience = String(req.body?.audience || 'direct');
      const recipientId = req.body?.recipientId;
      if (!body || body.length > 5000) return res.status(400).json({ error: 'Message must contain 1–5000 characters' });
      if (req.schoolMembership.role === 'parent' && audience !== 'direct') return res.status(403).json({ error: 'Parents can send direct messages only' });
      if (!['direct','all_parents','all_staff','all_school'].includes(audience)) return res.status(400).json({ error: 'Unsupported message audience' });
      if (audience === 'direct') {
        if (!mongoose.isValidObjectId(recipientId)) return res.status(400).json({ error: 'Choose a recipient' });
        const target = await Membership.findOne({ schoolId: req.params.schoolId, userId: recipientId, active: true });
        if (!target) return res.status(404).json({ error: 'Recipient is not a member of this school' });
        if (req.schoolMembership.role === 'parent' && !['admin','staff'].includes(target.role)) return res.status(403).json({ error: 'Parents may contact school administrators or staff only' });
      } else if (req.schoolMembership.role === 'staff') {
        return res.status(403).json({ error: 'Only school administrators can send school-wide announcements' });
      }
      const message = await SchoolMessage.create({ schoolId: req.params.schoolId, senderId: req.user._id, recipientId: audience === 'direct' ? recipientId : undefined, audience, subject: String(req.body?.subject || '').trim().slice(0,160), body });
      return res.status(201).json({ message });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/messages', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const member = req.schoolMembership;
      const visibility = member.role === 'parent'
        ? { $or: [{ audience: 'all_parents' }, { audience: 'all_school' }, { senderId: req.user._id }, { recipientId: req.user._id }] }
        : member.role === 'staff'
          ? { $or: [{ audience: 'all_staff' }, { audience: 'all_school' }, { senderId: req.user._id }, { recipientId: req.user._id }] }
          : { $or: [{ audience: { $in: ['all_parents','all_staff','all_school'] } }, { senderId: req.user._id }, { recipientId: req.user._id }] };
      const page = pageOptions(req);
      const filter = { schoolId: req.params.schoolId, ...visibility };
      const [messages, total] = await Promise.all([
        SchoolMessage.find(filter).sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).lean(),
        SchoolMessage.countDocuments(filter),
      ]);
      return res.json({ messages, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/conferences', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const title = String(req.body?.title || '').trim();
      const agenda = String(req.body?.agenda || '').trim();
      const startsAt = new Date(req.body?.startsAt);
      const endsAt = new Date(req.body?.endsAt);
      const audience = ['all_parents','all_staff','all_school'].includes(req.body?.audience) ? req.body.audience : 'all_parents';
      if (!title || title.length > 160 || !agenda || agenda.length > 5000 || !Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) || endsAt <= startsAt || startsAt < new Date(Date.now() - 60000)) return res.status(400).json({ error: 'Enter a title, agenda and valid future start/end times' });
      const meetingUrl = String(req.body?.meetingUrl || '').trim();
      if (meetingUrl && (!/^https:\/\//i.test(meetingUrl) || meetingUrl.length > 1000)) return res.status(400).json({ error: 'Meeting links must use HTTPS' });
      const conference = await SchoolConference.create({ schoolId: req.params.schoolId, createdBy: req.user._id, title, agenda, startsAt, endsAt, audience, location: String(req.body?.location || '').trim().slice(0,300), meetingUrl });
      return res.status(201).json({ conference });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/conferences', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const audience = req.schoolMembership.role === 'parent' ? ['all_parents','all_school'] : req.schoolMembership.role === 'staff' ? ['all_staff','all_school'] : ['all_parents','all_staff','all_school'];
      const page = pageOptions(req), filter = { schoolId: req.params.schoolId, audience: { $in: audience } };
      const [conferences, total] = await Promise.all([
        SchoolConference.find(filter).sort({ startsAt: 1 }).skip(page.skip).limit(page.limit).lean(),
        SchoolConference.countDocuments(filter),
      ]);
      return res.json({ conferences, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });


  // School register, attendance and assessment records. Every query is scoped to school membership.
  const SchoolStudent = model('SchoolStudent', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    admissionNumber: { type: String, required: true, trim: true, uppercase: true, maxlength: 40 },
    fullName: { type: String, required: true, trim: true, maxlength: 120 },
    className: { type: String, required: true, trim: true, maxlength: 80 },
    guardianName: { type: String, trim: true, maxlength: 120 },
    guardianPhone: { type: String, trim: true, maxlength: 30 },
    guardianEmail: { type: String, trim: true, lowercase: true, maxlength: 180 },
    active: { type: Boolean, default: true },
  }, { timestamps: true }));
  SchoolStudent.schema.index({ schoolId: 1, admissionNumber: 1 }, { unique: true });

  const SchoolAttendance = model('SchoolAttendance', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    studentId: { type: O, ref: 'SchoolStudent', required: true, index: true },
    studentName: { type: String, required: true }, admissionNumber: { type: String, required: true },
    className: { type: String, required: true }, date: { type: Date, required: true },
    status: { type: String, enum: ['present','absent','late','excused'], required: true },
    note: { type: String, trim: true, maxlength: 300 }, markedBy: { type: O, required: true },
  }, { timestamps: true }));
  SchoolAttendance.schema.index({ schoolId: 1, studentId: 1, date: 1 }, { unique: true });

  const SchoolAssessment = model('SchoolAssessment', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true }, studentId: { type: O, ref: 'SchoolStudent', required: true, index: true },
    studentName: { type: String, required: true }, admissionNumber: { type: String, required: true }, className: { type: String, required: true },
    subject: { type: String, required: true, trim: true, maxlength: 80 }, assessment: { type: String, required: true, trim: true, maxlength: 120 },
    term: { type: String, required: true, trim: true, maxlength: 80 }, score: { type: Number, required: true, min: 0 },
    outOf: { type: Number, required: true, min: 1 }, teacherNote: { type: String, trim: true, maxlength: 500 }, recordedBy: { type: O, required: true },
  }, { timestamps: true }));
  SchoolAssessment.schema.index({ schoolId: 1, studentId: 1, subject: 1, assessment: 1, term: 1 }, { unique: true });

  function schoolStudentFilter(req) {
    const filter = { schoolId: req.params.schoolId, active: true };
    if (req.schoolMembership.role === 'parent') {
      const names = (req.schoolMembership.studentNames || []).map(x => String(x).trim().toLowerCase());
      filter.$expr = { $in: [{ $toLower: '$fullName' }, names] };
    }
    return filter;
  }
  async function schoolVisibleStudents(req, page = pageOptions(req)) {
    return SchoolStudent.find(schoolStudentFilter(req)).sort({ className: 1, fullName: 1 }).skip(page.skip).limit(page.limit).lean();
  }
  app.get('/api/schools/:schoolId/students', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const page = pageOptions(req), filter = schoolStudentFilter(req);
      const [students, total] = await Promise.all([schoolVisibleStudents(req, page), SchoolStudent.countDocuments(filter)]);
      return res.json({ students, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/students', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const admissionNumber = String(req.body?.admissionNumber || '').trim().toUpperCase();
      const fullName = String(req.body?.fullName || '').trim();
      const className = String(req.body?.className || '').trim();
      if (!/^[A-Z0-9/-]{2,40}$/.test(admissionNumber) || !fullName || fullName.length > 120 || !className || className.length > 80)
        return res.status(400).json({ error: 'Enter a valid admission number, student name and class/grade' });
      const student = await SchoolStudent.create({ schoolId: req.params.schoolId, admissionNumber, fullName, className,
        guardianName: String(req.body?.guardianName || '').trim().slice(0,120),
        guardianPhone: String(req.body?.guardianPhone || '').trim().slice(0,30),
        guardianEmail: String(req.body?.guardianEmail || '').trim().toLowerCase().slice(0,180) });
      return res.status(201).json({ student });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'That admission number already exists in this school' });
      return next(error);
    }
  });

  app.patch('/api/schools/:schoolId/students/:studentId', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      if (!mongoose.isValidObjectId(req.params.studentId)) return res.status(400).json({ error: 'Invalid student record' });
      const update = {};
      for (const key of ['fullName','className','guardianName','guardianPhone','guardianEmail']) {
        if (req.body?.[key] !== undefined) update[key] = String(req.body[key]).trim();
      }
      if (req.body?.active !== undefined) update.active = req.body.active === true;
      const student = await SchoolStudent.findOneAndUpdate({ _id: req.params.studentId, schoolId: req.params.schoolId }, { $set: update }, { new: true, runValidators: true });
      if (!student) return res.status(404).json({ error: 'Student not found in this school' });
      return res.json({ student });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/attendance', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const page = pageOptions(req);
      const visibleStudents = await SchoolStudent.find(schoolStudentFilter(req)).select('_id').lean();
      const filter = { schoolId: req.params.schoolId, studentId: { $in: visibleStudents.map(s => s._id) } };
      if (req.query.date) {
        const date = new Date(String(req.query.date) + 'T00:00:00.000Z');
        if (!Number.isFinite(date.getTime())) return res.status(400).json({ error: 'Use attendance date YYYY-MM-DD' });
        filter.date = date;
      }
      const [attendance, total, students] = await Promise.all([
        SchoolAttendance.find(filter).sort({ date: -1, className: 1, studentName: 1 }).skip(page.skip).limit(page.limit).lean(),
        SchoolAttendance.countDocuments(filter),
        schoolVisibleStudents(req, page),
      ]);
      return res.json({ attendance, students, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/attendance', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const studentId = String(req.body?.studentId || ''), status = String(req.body?.status || '');
      const dateText = String(req.body?.date || new Date().toISOString().slice(0,10));
      const date = new Date(dateText + 'T00:00:00.000Z');
      if (!mongoose.isValidObjectId(studentId) || !['present','absent','late','excused'].includes(status) || !/^\d{4}-\d{2}-\d{2}$/.test(dateText) || !Number.isFinite(date.getTime()))
        return res.status(400).json({ error: 'Choose a student, valid date and attendance status' });
      const student = await SchoolStudent.findOne({ _id: studentId, schoolId: req.params.schoolId, active: true }).lean();
      if (!student) return res.status(404).json({ error: 'Active student not found in this school' });
      const record = await SchoolAttendance.findOneAndUpdate({ schoolId: req.params.schoolId, studentId, date },
        { $set: { studentName: student.fullName, admissionNumber: student.admissionNumber, className: student.className, status, note: String(req.body?.note || '').trim().slice(0,300), markedBy: req.user._id } },
        { upsert: true, new: true, runValidators: true, setDefaultsOnInsert: true });
      return res.json({ attendance: record });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/academics', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const page = pageOptions(req);
      const visibleStudents = await SchoolStudent.find(schoolStudentFilter(req)).select('_id').lean();
      const filter = { schoolId: req.params.schoolId, studentId: { $in: visibleStudents.map(s => s._id) } };
      const [assessments, total] = await Promise.all([
        SchoolAssessment.find(filter).sort({ term: -1, className: 1, studentName: 1, subject: 1 }).skip(page.skip).limit(page.limit).lean(),
        SchoolAssessment.countDocuments(filter),
      ]);
      return res.json({ assessments, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/academics', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const studentId = String(req.body?.studentId || ''), subject = String(req.body?.subject || '').trim();
      const assessment = String(req.body?.assessment || '').trim(), term = String(req.body?.term || '').trim();
      const score = Number(req.body?.score), outOf = Number(req.body?.outOf ?? 100);
      if (!mongoose.isValidObjectId(studentId) || !subject || subject.length > 80 || !assessment || assessment.length > 120 || !term || term.length > 80 ||
          !Number.isFinite(score) || !Number.isFinite(outOf) || outOf <= 0 || score < 0 || score > outOf || outOf > 10000)
        return res.status(400).json({ error: 'Enter student, subject, assessment, term and valid marks; score cannot exceed total marks' });
      const student = await SchoolStudent.findOne({ _id: studentId, schoolId: req.params.schoolId, active: true }).lean();
      if (!student) return res.status(404).json({ error: 'Active student not found in this school' });
      const record = await SchoolAssessment.create({ schoolId: req.params.schoolId, studentId, studentName: student.fullName, admissionNumber: student.admissionNumber,
        className: student.className, subject, assessment, term, score, outOf,
        teacherNote: String(req.body?.teacherNote || '').trim().slice(0,500), recordedBy: req.user._id });
      return res.status(201).json({ assessment: record });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'That assessment has already been recorded for this student and term' });
      return next(error);
    }
  });

  async function deliverSchoolReceipt(paymentId) {
    const payment = await FeePayment.findById(paymentId).select('+receiptHtml');
    if (!payment || payment.status !== 'CONFIRMED' || !payment.receiptHtml) return { sent: 0, pending: true };
    if (!emailProvider?.available || typeof emailProvider.sendSchoolFeeReceipt !== 'function') {
      await FeePayment.updateOne({ _id: payment._id }, { $set: { receiptEmailLastError: 'SMTP receipt email is not configured' } });
      return { sent: 0, pending: true };
    }
    const school = await School.findById(payment.schoolId).select('name code').lean();
    const parent = await User.findById(payment.parentId).select('name email').lean();
    const admins = await Membership.find({ schoolId: payment.schoolId, active: true, role: 'admin' }).select('userId').lean();
    const adminUsers = await User.find({ _id: { $in: admins.map(x => x.userId) } }).select('email').lean();
    const recipients = [...new Set([parent?.email, ...adminUsers.map(x => x.email)].filter(x => typeof x === 'string' && x.includes('@')))];
    let sent = 0;
    for (const email of recipients) {
      const latest = await FeePayment.findById(payment._id).select('receiptEmailSentTo').lean();
      if (latest?.receiptEmailSentTo?.includes(email)) continue;
      try {
        await emailProvider.sendSchoolFeeReceipt({ email, schoolName: school?.name || 'School', paymentReference: payment.paymentReference, receiptNumber: payment.mpesaReceipt, amount: payment.amount, studentName: payment.studentName, term: payment.term, receiptHtml: payment.receiptHtml });
        await FeePayment.updateOne({ _id: payment._id }, { $addToSet: { receiptEmailSentTo: email }, $unset: { receiptEmailLastError: 1 } });
        sent++;
      } catch (error) {
        await FeePayment.updateOne({ _id: payment._id }, { $set: { receiptEmailLastError: String(error?.message || 'Email delivery failed').slice(0, 300) } });
      }
    }
    const delivered = await FeePayment.findById(payment._id).select('receiptEmailSentTo').lean();
    return { sent, pending: recipients.some(email => !delivered?.receiptEmailSentTo?.includes(email)) };
  }


  // Financial fee records are intentionally not deletable; these routes cover
  // operational records and enforce school membership and role permissions.
  app.delete('/api/schools/:schoolId/messages/:messageId', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const message = await SchoolMessage.findOne({ _id: req.params.messageId, schoolId: req.params.schoolId });
      if (!message) return res.status(404).json({ error: 'School message not found' });
      if (req.schoolMembership.role !== 'admin' && String(message.senderId) !== String(req.user._id)) return res.status(403).json({ error: 'You may delete only messages you sent' });
      await SchoolMessage.deleteOne({ _id: message._id, schoolId: req.params.schoolId });
      return res.json({ deleted: true, id: String(message._id) });
    } catch (error) { return next(error); }
  });
  app.delete('/api/schools/:schoolId/conferences/:conferenceId', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const result = await SchoolConference.deleteOne({ _id: req.params.conferenceId, schoolId: req.params.schoolId });
      if (!result.deletedCount) return res.status(404).json({ error: 'Conference not found' });
      return res.json({ deleted: true, id: req.params.conferenceId });
    } catch (error) { return next(error); }
  });
  app.delete('/api/schools/:schoolId/students/:studentId', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const student = await SchoolStudent.findOneAndUpdate({ _id: req.params.studentId, schoolId: req.params.schoolId, active: true }, { $set: { active: false } }, { new: true });
      if (!student) return res.status(404).json({ error: 'Active student not found' });
      return res.json({ deleted: true, archived: true, id: String(student._id) });
    } catch (error) { return next(error); }
  });
  app.delete('/api/schools/:schoolId/attendance/:recordId', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const result = await SchoolAttendance.deleteOne({ _id: req.params.recordId, schoolId: req.params.schoolId });
      if (!result.deletedCount) return res.status(404).json({ error: 'Attendance record not found' });
      return res.json({ deleted: true, id: req.params.recordId });
    } catch (error) { return next(error); }
  });
  app.delete('/api/schools/:schoolId/academics/:recordId', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const result = await SchoolAssessment.deleteOne({ _id: req.params.recordId, schoolId: req.params.schoolId });
      if (!result.deletedCount) return res.status(404).json({ error: 'Assessment record not found' });
      return res.json({ deleted: true, id: req.params.recordId });
    } catch (error) { return next(error); }
  });
  app.delete('/api/schools/:schoolId/members/:memberId', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const member = await Membership.findOneAndUpdate({ _id: req.params.memberId, schoolId: req.params.schoolId, active: true }, { $set: { active: false } }, { new: true });
      if (!member) return res.status(404).json({ error: 'Active school member not found' });
      return res.json({ deleted: true, archived: true, id: String(member._id) });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fees', auth, requireRole('parent'), async (req, res, next) => {
    try {
      const studentName = String(req.body?.studentName || '').trim();
      const term = String(req.body?.term || '').trim();
      const amount = Number(req.body?.amount);
      const phone = normalizeMpesaPhone(String(req.body?.phone || req.user?.phone || ''));
      if (!studentName || studentName.length > 100 || !req.schoolMembership.studentNames.includes(studentName)) return res.status(403).json({ error: 'Choose a student linked to your parent account' });
      if (!Number.isSafeInteger(amount) || amount < 1 || amount > 150000 || !term || term.length > 80) return res.status(400).json({ error: 'Enter a valid whole-KSh amount and school term' });
      const school = await School.findById(req.params.schoolId).select('+paymentProfile.darajaConsumerKeyEnc +paymentProfile.darajaConsumerSecretEnc +paymentProfile.darajaPasskeyEnc').lean();
      if (!school?.paymentProfile?.method) return res.status(409).json({ error: 'This school has not configured payment details. Contact the school office before paying.' });
      const isMpesa = ['mpesa_paybill','mpesa_till'].includes(school.paymentProfile.method);
      if (isMpesa && !phone) return res.status(400).json({ error: 'Enter a valid Kenyan M-Pesa phone number to receive the school fee STK prompt.' });
      if (isMpesa && (!school.paymentProfile.darajaConsumerKeyEnc || !school.paymentProfile.darajaConsumerSecretEnc || !school.paymentProfile.darajaPasskeyEnc)) return res.status(409).json({ error: 'This school has configured a Paybill/Till destination but has not completed its own Daraja STK Push setup. Contact the school administrator; no payment prompt has been sent.' });
      const paymentReference = 'SCH-' + randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
      const payment = await FeePayment.create({ paymentReference, schoolId: school._id, parentId: req.user._id, studentName, amount, term, ...(isMpesa ? { payerPhone: phone, status: 'PENDING_STK' } : { status: 'PENDING_VERIFICATION' }) });
      if (isMpesa) {
        try {
          const provider = providerForSchool(school);
          const refs = await provider.initiate({ paymentId: paymentReference, amount, phone, description: 'School fees', now: new Date() });
          payment.checkoutRequestId = refs.checkoutRequestId;
          payment.merchantRequestId = refs.merchantRequestId;
          await payment.save();
          return res.status(201).json({ payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status, checkoutRequestId: payment.checkoutRequestId }, paymentDestination: { method: school.paymentProfile.method, paybillNumber: school.paymentProfile.paybillNumber, tillNumber: school.paymentProfile.tillNumber }, note: 'A school-specific M-Pesa STK Push was submitted to Safaricom. The fee is not confirmed until the Daraja callback verifies the amount, payer phone and receipt number.' });
        } catch (error) {
          await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK' }, { $set: { status: 'FAILED', callbackProcessedAt: new Date() } });
          console.error('School STK Push initiation failed', { schoolId: String(school._id), paymentReference, stage: error?.stage || 'configuration_or_unknown' });
          return res.status(503).json({ error: 'Safaricom could not start the school fee STK prompt. No receipt was issued. Check the school Daraja configuration and try again.' });
        }
      }
      return res.status(201).json({ payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status }, paymentDestination: school.paymentProfile, note: 'Bank payment details provided. This record remains pending until school staff verify the bank transaction.' });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fees', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const filter = { schoolId: req.params.schoolId };
      if (req.schoolMembership.role === 'parent') filter.parentId = req.user._id;
      const page = pageOptions(req);
      const [payments, total] = await Promise.all([
        FeePayment.find(filter).select('-receiptHtml -receiptEmailSentTo -receiptEmailLastError -payerPhone -checkoutRequestId -merchantRequestId').sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).lean(),
        FeePayment.countDocuments(filter),
      ]);
      const school = await School.findById(req.params.schoolId).select('name code paymentProfile.method paymentProfile.paybillNumber paymentProfile.tillNumber paymentProfile.bankName paymentProfile.accountNumber paymentProfile.darajaConfiguredAt').lean();
      const profile = school?.paymentProfile;
      const paymentOptions = {
        schoolName: school?.name || 'School',
        configured: Boolean(profile?.method),
        method: profile?.method || null,
        paybillNumber: profile?.method === 'mpesa_paybill' ? profile.paybillNumber : null,
        tillNumber: profile?.method === 'mpesa_till' ? profile.tillNumber : null,
        bankName: profile?.method === 'bank' ? profile.bankName : null,
        accountNumber: profile?.method === 'bank' ? profile.accountNumber : null,
        darajaConfigured: Boolean(profile?.darajaConfiguredAt),
      };
      return res.json({ payments, paymentOptions, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fees/:paymentReference/verify', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const receipt = String(req.body?.mpesaReceipt || '').trim().toUpperCase();
      if (!/^[A-Z0-9/-]{4,40}$/.test(receipt)) return res.status(400).json({ error: 'Enter the actual payment receipt/reference from the confirmed transaction' });
      const payment = await FeePayment.findOne({ schoolId: req.params.schoolId, paymentReference: req.params.paymentReference });
      if (!payment) return res.status(404).json({ error: 'Fee record not found' });
      if (payment.status === 'CONFIRMED') {
        if (payment.mpesaReceipt === receipt) return res.json({ payment, receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + payment.paymentReference + '/receipt' });
        return res.status(409).json({ error: 'This fee record is already confirmed with a different receipt' });
      }
      let confirmed;
      try {
        // Atomic compare-and-set prevents two administrators confirming the same
        // pending record with different receipt numbers at the same time.
        confirmed = await FeePayment.findOneAndUpdate(
          { _id: payment._id, status: 'PENDING_VERIFICATION' },
          { $set: { status: 'CONFIRMED', mpesaReceipt: receipt, verifiedBy: req.user._id, verifiedAt: new Date() } },
          { new: true, runValidators: true }
        );
      } catch (error) { if (error?.code === 11000) return res.status(409).json({ error: 'This M-Pesa receipt has already been used for another fee payment at this school' }); throw error; }
      if (!confirmed) {
        const latest = await FeePayment.findById(payment._id);
        if (latest?.status === 'CONFIRMED' && latest.mpesaReceipt === receipt) return res.json({ payment: latest, receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + latest.paymentReference + '/receipt', duplicate: true });
        return res.status(409).json({ error: 'This fee record has already been verified or changed. Refresh the fee list.' });
      }
      const school = await School.findById(req.params.schoolId).select('name code').lean();
      const receiptHtml = renderSchoolReceipt(school, confirmed);
      await FeePayment.updateOne({ _id: confirmed._id }, { $set: { receiptHtml } });
      await deliverSchoolReceipt(confirmed._id);
      return res.json({ payment: confirmed, receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + confirmed.paymentReference + '/receipt' });
    } catch (error) { return next(error); }
  });

  // Safaricom callback: require both request IDs and verify result, amount, payer phone,
  // and receipt before atomically confirming a school fee. Duplicate callbacks are harmless.
  app.post('/api/schools/daraja/callback', async (req, res, next) => {
    try {
      const cb = req.body?.Body?.stkCallback;
      if (!cb || typeof cb.CheckoutRequestID !== 'string' || typeof cb.MerchantRequestID !== 'string') return res.status(400).json({ error: 'Malformed Daraja callback' });
      const payment = await FeePayment.findOne({ checkoutRequestId: cb.CheckoutRequestID, merchantRequestId: cb.MerchantRequestID });
      if (!payment) return res.json({ ok: true, ignored: true });
      if (payment.callbackProcessedAt || ['CONFIRMED','FAILED','CANCELLED'].includes(payment.status)) return res.json({ ok: true, duplicate: true });
      const outcome = resolveCallbackOutcome(cb, { amount: payment.amount, totalAmount: payment.amount, phone: payment.payerPhone });
      if (outcome.error) {
        await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK', callbackProcessedAt: { $exists: false } }, { $set: { status: 'FAILED', callbackProcessedAt: new Date(), receiptEmailLastError: 'Daraja callback did not match the original amount or payer phone' } });
        return res.json({ ok: true, rejected: true });
      }
      if (outcome.status !== 'SUCCESS') {
        await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK', callbackProcessedAt: { $exists: false } }, { $set: { status: outcome.status, callbackProcessedAt: new Date() } });
        return res.json({ ok: true });
      }
      const items = Array.isArray(cb.CallbackMetadata?.Item) ? cb.CallbackMetadata.Item : [];
      const receipt = String(items.find(item => item?.Name === 'MpesaReceiptNumber')?.Value || '').trim().toUpperCase();
      if (!/^[A-Z0-9]{6,40}$/.test(receipt)) {
        await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK', callbackProcessedAt: { $exists: false } }, { $set: { status: 'FAILED', callbackProcessedAt: new Date(), receiptEmailLastError: 'Successful callback had no valid M-Pesa receipt number' } });
        return res.json({ ok: true, rejected: true });
      }
      const school = await School.findById(payment.schoolId).select('name code').lean();
      const verifiedAt = new Date();
      const receiptHtml = renderSchoolReceipt(school, { ...payment.toObject(), mpesaReceipt: receipt, verifiedAt });
      let confirmed;
      try {
        confirmed = await FeePayment.findOneAndUpdate(
          { _id: payment._id, status: 'PENDING_STK', callbackProcessedAt: { $exists: false } },
          { $set: { status: 'CONFIRMED', mpesaReceipt: receipt, verifiedAt, callbackProcessedAt: verifiedAt, receiptHtml } },
          { new: true, runValidators: true },
        );
      } catch (error) {
        if (error?.code === 11000) {
          await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK' }, { $set: { status: 'FAILED', callbackProcessedAt: new Date(), receiptEmailLastError: 'M-Pesa receipt already used for another school fee record' } });
          return res.json({ ok: true, rejected: true });
        }
        throw error;
      }
      if (!confirmed) return res.json({ ok: true, duplicate: true });
      res.json({ ok: true });
      deliverSchoolReceipt(confirmed._id).catch(error => console.error('School receipt delivery processing failed', { paymentReference: confirmed.paymentReference, message: String(error?.message || 'unknown').slice(0, 160) }));
      return;
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fees/:paymentReference/receipt/resend', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const payment = await FeePayment.findOne({ schoolId: req.params.schoolId, paymentReference: req.params.paymentReference });
      if (!payment || payment.status !== 'CONFIRMED') return res.status(409).json({ error: 'Only confirmed payments have receipts that can be delivered' });
      const result = await deliverSchoolReceipt(payment._id);
      return res.json({ receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + payment.paymentReference + '/receipt', emailDelivery: result });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fees/:paymentReference/receipt', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const payment = await FeePayment.findOne({ schoolId: req.params.schoolId, paymentReference: req.params.paymentReference }).select('+receiptHtml').lean();
      if (!payment) return res.status(404).json({ error: 'Fee record not found' });
      if (req.schoolMembership.role === 'parent' && String(payment.parentId) !== String(req.user._id)) return res.status(403).json({ error: 'This receipt belongs to another parent' });
      if (payment.status !== 'CONFIRMED') return res.status(409).json({ error: 'Receipt unavailable until the school verifies payment' });
      const receipt = payment.receiptHtml || renderSchoolReceipt(await School.findById(req.params.schoolId).select('name code').lean(), payment);
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Content-Disposition', 'attachment; filename="school-fee-receipt-' + payment.paymentReference + '.html"');
      return res.send(receipt);

    } catch (error) { return next(error); }
  });
}
