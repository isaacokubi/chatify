// School communication, conferences and fee-ledger API.
// All school records are scoped to the authenticated user's school membership.
// A fee receipt is available only after an authorized staff member verifies payment.
import { randomUUID } from 'node:crypto';

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

export function registerSchoolRoutes({ app, auth, mongoose, User }) {
  const O = mongoose.Schema.Types.ObjectId;
  const model = (name, schema) => mongoose.models[name] || mongoose.model(name, schema);
  const School = model('SchoolWorkspace', new mongoose.Schema({
    name: { type: String, required: true, trim: true, maxlength: 160 },
    code: { type: String, required: true, trim: true, uppercase: true, maxlength: 24 },
    createdBy: { type: O, ref: 'User', required: true },
    paymentProfile: { method: { type: String, enum: ['mpesa_paybill','mpesa_till','bank'] }, paybillNumber: String, tillNumber: String, accountNumber: String, bankName: String },
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
    status: { type: String, enum: ['PENDING_VERIFICATION','CONFIRMED','REJECTED'], default: 'PENDING_VERIFICATION', index: true },
    mpesaReceipt: { type: String, trim: true, uppercase: true, maxlength: 40 },
    verifiedBy: O,
    verifiedAt: Date,
  }, { timestamps: true }));
  FeePayment.schema.index({ schoolId: 1, mpesaReceipt: 1 }, { unique: true, sparse: true });

  async function membership(req, schoolId) {
    if (!mongoose.isValidObjectId(schoolId)) return null;
    return Membership.findOne({ schoolId, userId: req.user._id, active: true });
  }
  const requireRole = (...roles) => async (req, res, next) => {
    try {
      const member = await membership(req, req.params.schoolId || req.params.id);
      if (!member) return res.status(403).json({ error: 'You are not a member of this school' });
      if (!roles.includes(member.role)) return res.status(403).json({ error: 'Your school role cannot perform this action' });
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
      return res.status(201).json({ school: { id: String(school._id), name: school.name, code: school.code }, role: 'admin' });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'That school code is already in use' });
      return next(error);
    }
  });

  app.get('/api/schools', auth, async (req, res, next) => {
    try {
      const memberships = await Membership.find({ userId: req.user._id, active: true }).lean();
      const ids = memberships.map(m => m.schoolId);
      const schools = await School.find({ _id: { $in: ids } }).select('name code paymentProfile').lean();
      return res.json({ schools: schools.map(s => ({ id: String(s._id), name: s.name, code: s.code, role: memberships.find(m => String(m.schoolId) === String(s._id))?.role, paymentProfile: s.paymentProfile?.method ? { method: s.paymentProfile.method, paybillNumber: s.paymentProfile.paybillNumber, tillNumber: s.paymentProfile.tillNumber, accountNumber: s.paymentProfile.accountNumber, bankName: s.paymentProfile.bankName } : null })) });
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

  app.get('/api/schools/:schoolId/members', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const rows = await Membership.find({ schoolId: req.params.schoolId, active: true }).populate('userId', 'name email').lean();
      return res.json({ members: rows.filter(x => x.userId).map(x => ({ id: String(x._id), userId: String(x.userId._id), name: x.userId.name, email: x.userId.email, role: x.role, studentNames: x.studentNames })) });
    } catch (error) { return next(error); }
  });

  app.put('/api/schools/:schoolId/payment-profile', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const profile = normalizeSchoolPaymentProfile(req.body || {});
      await School.updateOne({ _id: req.params.schoolId }, { $set: { paymentProfile: profile } });
      return res.json({ paymentProfile: profile, note: 'Payment details saved. This configures the destination only; it does not activate automated STK Push.' });
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
      const messages = await SchoolMessage.find({ schoolId: req.params.schoolId, ...visibility }).sort({ createdAt: -1 }).limit(100).lean();
      return res.json({ messages });
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
      const conferences = await SchoolConference.find({ schoolId: req.params.schoolId, audience: { $in: audience } }).sort({ startsAt: 1 }).limit(100).lean();
      return res.json({ conferences });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fees', auth, requireRole('parent'), async (req, res, next) => {
    try {
      const studentName = String(req.body?.studentName || '').trim();
      const term = String(req.body?.term || '').trim();
      const amount = Number(req.body?.amount);
      if (!studentName || studentName.length > 100 || !req.schoolMembership.studentNames.includes(studentName)) return res.status(403).json({ error: 'Choose a student linked to your parent account' });
      if (!Number.isSafeInteger(amount) || amount < 1 || amount > 150000 || !term || term.length > 80) return res.status(400).json({ error: 'Enter a valid whole-KSh amount and school term' });
      const school = await School.findById(req.params.schoolId).select('name paymentProfile').lean();
      if (!school?.paymentProfile?.method) return res.status(409).json({ error: 'This school has not configured payment details. Contact the school office before paying.' });
      const paymentReference = 'SCH-' + randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
      const payment = await FeePayment.create({ paymentReference, schoolId: school._id, parentId: req.user._id, studentName, amount, term });
      return res.status(201).json({
        payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status },
        paymentDestination: school.paymentProfile,
        note: 'This is a pending fee record, not proof of payment. Automated in-app STK Push is not enabled for this school integration yet. A receipt will be issued only after the school verifies the payment.'
      });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fees', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const filter = { schoolId: req.params.schoolId };
      if (req.schoolMembership.role === 'parent') filter.parentId = req.user._id;
      const payments = await FeePayment.find(filter).sort({ createdAt: -1 }).limit(200).lean();
      return res.json({ payments });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fees/:paymentReference/verify', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const receipt = String(req.body?.mpesaReceipt || '').trim().toUpperCase();
      if (!/^[A-Z0-9]{6,40}$/.test(receipt)) return res.status(400).json({ error: 'Enter the actual M-Pesa receipt/reference from the confirmed transaction' });
      const payment = await FeePayment.findOne({ schoolId: req.params.schoolId, paymentReference: req.params.paymentReference });
      if (!payment) return res.status(404).json({ error: 'Fee record not found' });
      if (payment.status === 'CONFIRMED') {
        if (payment.mpesaReceipt === receipt) return res.json({ payment, receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + payment.paymentReference + '/receipt' });
        return res.status(409).json({ error: 'This fee record is already confirmed with a different receipt' });
      }
      try {
        payment.status = 'CONFIRMED'; payment.mpesaReceipt = receipt; payment.verifiedBy = req.user._id; payment.verifiedAt = new Date();
        await payment.save();
      } catch (error) { if (error?.code === 11000) return res.status(409).json({ error: 'This M-Pesa receipt has already been used for another fee payment at this school' }); throw error; }
      return res.json({ payment, receiptUrl: '/api/schools/' + req.params.schoolId + '/fees/' + payment.paymentReference + '/receipt' });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fees/:paymentReference/receipt', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const payment = await FeePayment.findOne({ schoolId: req.params.schoolId, paymentReference: req.params.paymentReference }).lean();
      if (!payment) return res.status(404).json({ error: 'Fee record not found' });
      if (req.schoolMembership.role === 'parent' && String(payment.parentId) !== String(req.user._id)) return res.status(403).json({ error: 'This receipt belongs to another parent' });
      if (payment.status !== 'CONFIRMED') return res.status(409).json({ error: 'Receipt unavailable until the school verifies payment' });
      const school = await School.findById(req.params.schoolId).select('name code').lean();
      const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Content-Disposition', 'attachment; filename="school-fee-receipt-' + payment.paymentReference + '.html"');
      return res.send('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>School fee receipt</title><style>body{font:16px system-ui,sans-serif;max-width:720px;margin:32px auto;padding:24px;color:#172033}main{border:1px solid #ccd3df;border-radius:16px;padding:28px}h1{margin-top:0}dt{font-weight:700;margin-top:14px}dd{margin:4px 0}button{padding:10px 16px}@media print{button{display:none}body{margin:0}}</style></head><body><main><h1>' + esc(school?.name || 'School') + '</h1><h2>Official school fee receipt</h2><p>Payment confirmed by the school.</p><dl><dt>Receipt number</dt><dd>' + esc(payment.mpesaReceipt) + '</dd><dt>Chatify reference</dt><dd>' + esc(payment.paymentReference) + '</dd><dt>Student</dt><dd>' + esc(payment.studentName) + '</dd><dt>Term</dt><dd>' + esc(payment.term) + '</dd><dt>Amount received</dt><dd>KSh ' + esc(payment.amount.toLocaleString('en-KE')) + '</dd><dt>Verified on</dt><dd>' + esc(payment.verifiedAt?.toISOString?.() || '') + '</dd></dl><button onclick="window.print()">Print receipt</button></main></body></html>');
    } catch (error) { return next(error); }
  });
}
