// School communication, conferences and fee-ledger API.
// All school records are scoped to the authenticated user's school membership.
// A fee receipt is available only after an authorized staff member verifies payment.
import { randomUUID, randomBytes, createCipheriv, createDecipheriv, createHash } from 'node:crypto';
import { createDarajaProvider, normalizeMpesaPhone, resolveCallbackOutcome } from './payments.js';
import {getWorkspaceBillingStatus} from './workspace-billing-access.js';
import {normalizeFeeStructureInput, calculateSchoolFeeBalance} from './school-fees.js';

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

export function schoolPaymentMethodLabel(method) {
  const raw = String(method ?? '').trim().toLowerCase().replace(/[\s-]+/g, '_');
  return ({
    mpesa_paybill: 'M-Pesa Paybill', paybill: 'M-Pesa Paybill', m_pesa_paybill: 'M-Pesa Paybill',
    mpesa_till: 'M-Pesa Till', till: 'M-Pesa Till', buy_goods: 'M-Pesa Till', m_pesa_till: 'M-Pesa Till',
    mpesa_send_money: 'M-Pesa Send Money', send_money: 'M-Pesa Send Money', m_pesa_send_money: 'M-Pesa Send Money',
    mpesa_stk: 'M-Pesa (STK Push)', mpesa_stk_push: 'M-Pesa (STK Push)', 'm_pesa_(stk_push)': 'M-Pesa (STK Push)', stk: 'M-Pesa (STK Push)', stk_push: 'M-Pesa (STK Push)', daraja: 'M-Pesa (STK Push)',
    bank: 'Bank transfer', bank_transfer: 'Bank transfer', banktransfer: 'Bank transfer',
  })[raw] || null;
}

function renderSchoolReceipt(school, payment) {
  const esc = escapeReceipt;
  const method = schoolPaymentMethodLabel(payment.paymentMethod || payment.method || school?.paymentProfile?.method) || 'Not recorded';
  const stamp = typeof school?.receiptStampDataUrl === 'string' &&
    /^data:image\/jpeg;base64,[A-Za-z0-9+/=\r\n]+$/.test(school.receiptStampDataUrl)
    ? '<img class="stamp" alt="School official stamp" src="' + school.receiptStampDataUrl + '">'
    : '';
  const amount = Number(payment.amount);
  const money = Number.isFinite(amount) ? amount.toLocaleString('en-KE', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) : '—';
  const verified = payment.verifiedAt ? new Date(payment.verifiedAt).toLocaleString('en-KE') : 'Recorded by school';
  return '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Official school fee receipt</title><style>*{box-sizing:border-box}body{font:15px/1.55 Arial,Helvetica,sans-serif;max-width:760px;margin:28px auto;padding:20px;color:#172b4d;background:#f3f6fb}.receipt{background:#fff;border:1px solid #d8e1ee;border-radius:16px;overflow:hidden;box-shadow:0 8px 28px #102a4310}.brand{padding:26px 30px;background:#12345a;color:#fff;border-bottom:5px solid #25a18e}.brand h1{font-size:25px;letter-spacing:.2px;margin:0 0 4px}.brand p{margin:0;color:#dce8f5;font-size:12px;text-transform:uppercase;letter-spacing:1.3px}.body{padding:26px 30px}.title{display:flex;align-items:center;justify-content:space-between;gap:16px;margin-bottom:20px}.title h2{margin:0;font-size:20px}.status{background:#e5f7ef;color:#17684f;border-radius:20px;padding:5px 11px;font-size:11px;font-weight:bold;white-space:nowrap}.amount{background:#f0f7ff;border:1px solid #d5e7fb;border-radius:12px;padding:16px 18px;margin:18px 0}.amount small{display:block;color:#58708d;text-transform:uppercase;font-size:11px;font-weight:bold;letter-spacing:1px}.amount strong{display:block;font-size:29px;color:#12345a;margin-top:4px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px 24px;margin:20px 0}.field{border-bottom:1px solid #e5ebf3;padding-bottom:9px;min-width:0}.field span{display:block;color:#6b7c93;font-size:11px;text-transform:uppercase;letter-spacing:.65px;font-weight:bold}.field strong{display:block;margin-top:4px;overflow-wrap:anywhere;font-size:14px}.footer{display:flex;align-items:flex-end;justify-content:space-between;gap:20px;border-top:1px solid #e5ebf3;padding-top:18px;margin-top:24px}.fine{font-size:11px;color:#6b7c93;max-width:60%}.stamp{display:block;max-width:150px;max-height:100px;object-fit:contain;opacity:.93}.actions{padding:0 30px 26px}button{background:#12345a;color:#fff;border:0;border-radius:8px;padding:11px 18px;font-weight:bold;cursor:pointer}@media(max-width:560px){body{padding:8px;margin:8px auto}.body,.brand{padding:20px}.grid{grid-template-columns:1fr}.title{align-items:flex-start;flex-direction:column}.footer{align-items:flex-start;flex-direction:column}.fine{max-width:100%}}@media print{body{margin:0;padding:0;background:#fff}.receipt{box-shadow:none;border-radius:0}.actions{display:none}}</style></head><body><main class="receipt"><header class="brand"><h1>' + esc(school?.name || 'School') + '</h1><p>Official school fee receipt</p></header><section class="body"><div class="title"><h2>Payment confirmation</h2><span class="status">PAYMENT CONFIRMED</span></div><p>This receipt confirms that the school has recorded the payment details below.</p><div class="amount"><small>Amount received</small><strong>KSh ' + esc(money) + '</strong></div><div class="grid"><div class="field"><span>Official receipt number</span><strong>' + esc(payment.mpesaReceipt || 'Not supplied') + '</strong></div><div class="field"><span>Chatify payment reference</span><strong>' + esc(payment.paymentReference || '—') + '</strong></div><div class="field"><span>Student name</span><strong>' + esc(payment.studentName || '—') + '</strong></div><div class="field"><span>Term / fee period</span><strong>' + esc(payment.term || '—') + '</strong></div><div class="field"><span>Payment method</span><strong>' + esc(method) + '</strong></div><div class="field"><span>Date verified</span><strong>' + esc(verified) + '</strong></div><div class="field"><span>Total term charge</span><strong>' + (Number.isSafeInteger(payment.chargeAmount) ? 'KSh ' + esc(Number(payment.chargeAmount).toLocaleString('en-KE')) : 'Refer to the school fee statement') + '</strong></div><div class="field"><span>Remaining balance</span><strong>' + (Number.isSafeInteger(payment.balance) ? 'KSh ' + esc(Number(payment.balance).toLocaleString('en-KE')) : 'Refer to the school fee statement') + '</strong></div></div><div class="footer"><div class="fine">Please retain this receipt for your records. For payment enquiries, quote the Chatify payment reference. Generated by Chatify; payment verification remains the responsibility of the school.</div>' + stamp + '</div></section><div class="actions"><button onclick="window.print()">Print / Save as PDF</button></div></main></body></html>';
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

export function resolveSchoolMessageDestination(role, requestedAudience, recipientId) {
  const audience = String(requestedAudience || 'direct');
  const allowed = ['direct', 'all_parents', 'all_staff', 'all_school', 'school_inbox'];
  if (!['admin', 'staff', 'parent'].includes(role)) return { error: 'Your school role cannot send messages.' };
  if (['parent', 'staff'].includes(role)) {
    if (audience !== 'school_inbox' || recipientId) {
      return { error: 'Parents and staff must send messages to their school inbox; individual platform administrator recipients are not available.' };
    }
    return { audience: 'school_inbox', recipientId: undefined };
  }
  if (!allowed.includes(audience)) return { error: 'Unsupported message audience.' };
  return { audience, recipientId: audience === 'direct' ? recipientId : undefined };
}

export function registerSchoolRoutes({ app, auth, mongoose, User, emailProvider, platformFeeCollector }) {
  const O = mongoose.Schema.Types.ObjectId;
  const model = (name, schema) => mongoose.models[name] || mongoose.model(name, schema);
  const School = model('SchoolWorkspace', new mongoose.Schema({
    name: { type: String, required: true, trim: true, maxlength: 160 },
    code: { type: String, required: true, trim: true, uppercase: true, maxlength: 24 },
    officialPhone: { type: String, trim: true, maxlength: 24 },
    receiptStampDataUrl: { type: String, trim: true, maxlength: 1000000, default: '' },
    staffInviteCode: { type: String, default: () => randomUUID().replace(/-/g, '').slice(0, 16).toUpperCase(), select: false },
    createdBy: { type: O, ref: 'User', required: true },
    billing: { type: mongoose.Schema.Types.Mixed, default: {} },
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
  // A workspace is not created until a platform reviewer verifies that the school is real.
  const SchoolVerificationRequest = model('SchoolVerificationRequest', new mongoose.Schema({
    requesterId: { type: O, ref: 'User', required: true, index: true },
    schoolName: { type: String, required: true, trim: true, maxlength: 160 },
    proposedCode: { type: String, required: true, trim: true, uppercase: true, maxlength: 24 },
    county: { type: String, required: true, trim: true, maxlength: 80 },
    officialEmail: { type: String, required: true, trim: true, lowercase: true, maxlength: 254 },
    officialPhone: { type: String, required: true, trim: true, maxlength: 24 },
    status: { type: String, enum: ['PENDING','APPROVED','REJECTED'], default: 'PENDING', index: true },
    reviewedBy: { type: O, ref: 'User' },
    reviewedAt: Date,
    reviewNote: { type: String, trim: true, maxlength: 500 },
    schoolId: { type: O, ref: 'SchoolWorkspace' },
  }, { timestamps: true }));
  SchoolVerificationRequest.schema.index({ requesterId: 1, proposedCode: 1, status: 1 });
  const SchoolMessage = model('SchoolMessage', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    senderId: { type: O, ref: 'User', required: true, index: true },
    recipientId: { type: O, index: true },
    audience: { type: String, enum: ['direct','all_parents','all_staff','all_school','school_inbox'], default: 'direct' },
    messageType: { type: String, enum: ['message','conference'], default: 'message', index: true },
    startsAt: { type: Date },
    endsAt: { type: Date },
    location: { type: String, trim: true, maxlength: 300 },
    subject: { type: String, trim: true, maxlength: 160 },
    body: { type: String, required: true, trim: true, maxlength: 5000 },
  }, { timestamps: true }));
  const FeePayment = model('SchoolFeePayment', new mongoose.Schema({
    paymentReference: { type: String, required: true, unique: true, index: true },
    schoolId: { type: O, required: true, index: true },
    parentId: { type: O, required: true, index: true },
    studentName: { type: String, required: true, trim: true, maxlength: 100 },
    studentId: { type: O, ref: 'SchoolStudent', index: true },
    className: { type: String, trim: true, maxlength: 80 },
    academicYear: { type: String, trim: true, maxlength: 40 },
    chargeId: { type: O, ref: 'SchoolStudentCharge', index: true },
    amount: { type: Number, required: true, min: 1, max: 150000 },
    term: { type: String, required: true, trim: true, maxlength: 80 },
    status: { type: String, enum: ['PENDING_STK','PENDING_VERIFICATION','CONFIRMED','FAILED','CANCELLED','REJECTED'], default: 'PENDING_VERIFICATION', index: true },
    paymentMethod: { type: String, enum: ['mpesa_paybill','mpesa_till','mpesa_send_money','bank'] },
    destinationNumber: { type: String, trim: true },
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

  // Fee structures are versioned templates. Issued student charges copy the item
  // list and total so a later edit cannot silently rewrite historical liabilities.
  const SchoolFeeStructure = model('SchoolFeeStructure', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    className: { type: String, required: true, trim: true, maxlength: 80 },
    academicYear: { type: String, required: true, trim: true, maxlength: 40 },
    term: { type: String, required: true, trim: true, maxlength: 80 },
    version: { type: Number, required: true, min: 1 },
    items: [{ code: { type: String, required: true }, description: { type: String, required: true }, amount: { type: Number, required: true, min: 1 } }],
    totalAmount: { type: Number, required: true, min: 1 },
    status: { type: String, enum: ['ACTIVE', 'ARCHIVED'], default: 'ACTIVE', index: true },
    createdBy: { type: O, required: true },
    updatedBy: { type: O, required: true },
    archivedAt: Date,
  }, { timestamps: true }));
  SchoolFeeStructure.schema.index({ schoolId: 1, className: 1, academicYear: 1, term: 1, version: 1 }, { unique: true });
  SchoolFeeStructure.schema.index({ schoolId: 1, className: 1, academicYear: 1, term: 1, status: 1 });

  const SchoolStudentCharge = model('SchoolStudentCharge', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    studentId: { type: O, ref: 'SchoolStudent', required: true, index: true },
    studentName: { type: String, required: true, trim: true, maxlength: 120 },
    admissionNumber: { type: String, required: true, trim: true, maxlength: 40 },
    className: { type: String, required: true, trim: true, maxlength: 80 },
    academicYear: { type: String, required: true, trim: true, maxlength: 40 },
    term: { type: String, required: true, trim: true, maxlength: 80 },
    items: [{ code: { type: String, required: true }, description: { type: String, required: true }, amount: { type: Number, required: true, min: 1 } }],
    totalAmount: { type: Number, required: true, min: 1 },
    credits: { type: Number, default: 0, min: 0 },
    structureId: { type: O, ref: 'SchoolFeeStructure', required: true },
    structureVersion: { type: Number, required: true },
    issuedBy: { type: O, required: true },
    issuedAt: { type: Date, default: Date.now },
  }, { timestamps: true }));
  SchoolStudentCharge.schema.index({ schoolId: 1, studentId: 1, academicYear: 1, term: 1 }, { unique: true });
  SchoolStudentCharge.schema.index({ schoolId: 1, className: 1, academicYear: 1, term: 1 });

  const SchoolStudent = model('SchoolStudent', new mongoose.Schema({
    schoolId: { type: O, required: true, index: true },
    admissionNumber: { type: String, required: true, trim: true, uppercase: true, maxlength: 40 },
    fullName: { type: String, required: true, trim: true, maxlength: 120 },
    className: { type: String, required: true, trim: true, maxlength: 80 },
    guardianName: { type: String, trim: true, maxlength: 120 },
    guardianPhone: { type: String, trim: true, maxlength: 30 },
    guardianEmail: { type: String, trim: true, lowercase: true, maxlength: 180 },
    active: { type: Boolean, default: true },
    // Promotion history makes year-end class changes auditable and prevents a class
    // from being promoted twice for the same academic year.
    promotionHistory: [{
      fromClass: { type: String, required: true, trim: true, maxlength: 80 },
      toClass: { type: String, required: true, trim: true, maxlength: 80 },
      academicYear: { type: String, required: true, trim: true, maxlength: 40 },
      promotedAt: { type: Date, required: true },
      promotedBy: { type: O, ref: 'User', required: true },
    }],
    transferredOutAt: Date,
    transferredOutBy: { type: O, ref: 'User' },
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
    if (['parent', 'staff'].includes(req.schoolMembership.role)) {
      // Parents and staff see only pupils explicitly linked to their membership.
      // An empty list intentionally matches no student records.
      const names = (req.schoolMembership.studentNames || []).map(x => String(x).trim().toLowerCase()).filter(Boolean);
      filter.$expr = { $in: [{ $toLower: '$fullName' }, names] };
    }
    return filter;
  }


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
      const billingSchool = await School.findById(schoolId).select('billing').lean();
      if (billingSchool?.billing?.billingEnforced === true) {
        const settings = await mongoose.models.WorkspaceBillingSettings?.findOne({key:'global'}).select('gracePeriodDays').lean();
        const status = getWorkspaceBillingStatus(billingSchool, Number(settings?.gracePeriodDays ?? 3));
        if (status.locked) return res.status(402).json({error: 'This school workspace is locked because its setup fee or monthly subscription is unpaid or expired.', code: 'WORKSPACE_BILLING_REQUIRED', billing: status});
      }
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

  function isSchoolVerificationAdmin(req) {
    const allowed = String(process.env.SCHOOL_VERIFICATION_ADMIN_EMAILS || '')
      .split(',').map(value => value.trim().toLowerCase()).filter(Boolean);
    const email = String(req.user?.email || '').trim().toLowerCase();
    return allowed.length > 0 && email.length > 0 && allowed.includes(email);
  }

  // Anyone may request verification, but a request alone never creates a workspace.
  app.post('/api/schools/verification-requests', auth, async (req, res, next) => {
    try {
      const schoolName = String(req.body?.schoolName || '').trim();
      const proposedCode = String(req.body?.proposedCode || '').trim().toUpperCase();
      const county = String(req.body?.county || '').trim();
      const officialEmail = String(req.body?.officialEmail || '').trim().toLowerCase();
      const officialPhone = String(req.body?.officialPhone || '').trim();
      if (!schoolName || schoolName.length > 160 || !/^[A-Z0-9-]{3,24}$/.test(proposedCode) ||
          !county || county.length > 80 || !/^\\S+@\\S+\\.\\S+$/.test(officialEmail) ||
          officialEmail.length > 254 || !/^[+0-9() -]{9,24}$/.test(officialPhone)) {
        return res.status(400).json({ error: 'Enter the school name, proposed code, county, official school email and phone number.' });
      }
      if (await School.exists({ code: proposedCode })) return res.status(409).json({ error: 'A workspace already uses that school code. Contact support if it belongs to your school.' });
      const requesterPendingCount = await SchoolVerificationRequest.countDocuments({ requesterId: req.user._id, status: 'PENDING' });
      if (requesterPendingCount >= 3) return res.status(429).json({ error: 'You already have three pending school verification requests. Wait for review before submitting another.' });
      const pending = await SchoolVerificationRequest.findOne({ proposedCode, status: 'PENDING' });
      if (pending) return res.status(409).json({ error: 'A verification request for that school code is already pending.' });
      const request = await SchoolVerificationRequest.create({
        requesterId: req.user._id, schoolName, proposedCode, county, officialEmail, officialPhone,
      });
      return res.status(202).json({ request: { id: String(request._id), schoolName, proposedCode, county, status: request.status, createdAt: request.createdAt },
        message: 'Request received. The workspace will not be created until Chatify verifies the school.' });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'A request for this school code already exists.' });
      return next(error);
    }
  });

  app.get('/api/schools/verification-requests', auth, async (req, res, next) => {
    try {
      const filter = isSchoolVerificationAdmin(req)
        ? { status: 'PENDING' }
        : { requesterId: req.user._id };
      const requests = await SchoolVerificationRequest.find(filter).sort({ createdAt: -1 }).limit(100).lean();
      return res.json({ requests: requests.map(item => ({
        id: String(item._id), schoolName: item.schoolName, proposedCode: item.proposedCode,
        county: item.county, officialEmail: item.officialEmail, officialPhone: item.officialPhone,
        status: item.status, reviewNote: item.reviewNote || '', createdAt: item.createdAt,
      })), reviewer: isSchoolVerificationAdmin(req) });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/verification-requests/:requestId/review', auth, async (req, res, next) => {
    try {
      if (!isSchoolVerificationAdmin(req)) return res.status(403).json({ error: 'Only an authorized Chatify school-verification reviewer can approve or reject schools.' });
      const decision = String(req.body?.decision || '').toUpperCase();
      const reviewNote = String(req.body?.reviewNote || '').trim().slice(0, 500);
      if (!['APPROVE', 'REJECT'].includes(decision)) return res.status(400).json({ error: 'Choose APPROVE or REJECT.' });
      const request = await SchoolVerificationRequest.findOne({ _id: req.params.requestId, status: 'PENDING' });
      if (!request) return res.status(404).json({ error: 'Pending school verification request not found.' });
      if (decision === 'REJECT') {
        request.status = 'REJECTED'; request.reviewedBy = req.user._id;
        request.reviewedAt = new Date(); request.reviewNote = reviewNote || 'School identity could not be verified.';
        await request.save();
        return res.json({ status: request.status, message: 'Request rejected. No school workspace was created.' });
      }
      if (await School.exists({ code: request.proposedCode })) return res.status(409).json({ error: 'That school code has already been registered. Ask the requester to submit a new request.' });
      const school = await School.create({ name: request.schoolName, code: request.proposedCode, officialPhone: request.officialPhone, createdBy: request.requesterId, billing: {billingEnforced: true, setupFeePaid: false, subscriptionExpiresAt: null, status: 'SETUP_PAYMENT_REQUIRED'} });
      await Membership.create({ schoolId: school._id, userId: request.requesterId, role: 'admin' });
      request.status = 'APPROVED'; request.reviewedBy = req.user._id; request.reviewedAt = new Date();
      request.reviewNote = reviewNote; request.schoolId = school._id;
      await request.save();
      return res.json({ status: request.status, school: { id: String(school._id), name: school.name, code: school.code }, message: 'School verified and workspace created.' });
    } catch (error) {
      if (error?.code === 11000) return res.status(409).json({ error: 'That school code is already in use. No duplicate workspace was created.' });
      return next(error);
    }
  });

  // Legacy direct creation is disabled to stop unverified or fabricated schools.
  // Only an approved verification request may create a production workspace.
  app.post('/api/schools', auth, async (_req, res) => {
    return res.status(403).json({ error: 'School workspaces require verification first. Submit a school verification request instead.' });
  });

  app.get('/api/schools', auth, async (req, res, next) => {
    try {
      const memberships = await Membership.find({ userId: req.user._id, active: true }).lean();
      const ids = memberships.map(m => m.schoolId);
      const schools = await School.find({ _id: { $in: ids } }).select('+staffInviteCode name code officialPhone createdBy paymentProfile.method paymentProfile.paybillNumber paymentProfile.tillNumber paymentProfile.accountNumber paymentProfile.bankName paymentProfile.darajaMode paymentProfile.darajaConfiguredAt').lean();
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
      return res.json({ schools: schools.map(s => ({ id: String(s._id), name: s.name, code: s.code, officialPhone: s.officialPhone || '', role: memberships.find(m => String(m.schoolId) === String(s._id))?.role, isOwner: String(s.createdBy) === String(req.user._id), staffInviteCode: memberships.find(m => String(m.schoolId) === String(s._id))?.role === 'admin' ? s.staffInviteCode : undefined, paymentProfile: s.paymentProfile?.method ? { method: s.paymentProfile.method, paybillNumber: s.paymentProfile.paybillNumber, tillNumber: s.paymentProfile.tillNumber, accountNumber: s.paymentProfile.accountNumber, bankName: s.paymentProfile.bankName, darajaMode: s.paymentProfile.darajaMode, darajaConfigured: Boolean(s.paymentProfile.darajaConfiguredAt) } : null })) });
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
      if (studentNames.length === 0) {
        return res.status(400).json({ error: 'Parents and staff must enter at least one linked student name. Use the exact registered student name(s) supplied by the school office.' });
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
      const q = String(req.query.q || '').trim().slice(0, 120);
      const filter = { schoolId: req.params.schoolId, active: true };
      // Non-admin members must not browse the other families' directory entries.
      if (['parent', 'staff'].includes(req.schoolMembership.role)) filter.role = { $in: ['admin','staff'] };
      if (req.query.role && ['admin','staff','parent'].includes(String(req.query.role)) && req.schoolMembership.role === 'admin') {
        filter.role = String(req.query.role);
      }
      if (q) {
        const safe = q.replace(/[.*+?^${}()|[\]\\]/g, (match) => `\\${match}`);
        const users = await User.find({
          $or: [{ name: { $regex: safe, $options: 'i' } }, { email: { $regex: safe, $options: 'i' } }],
        }).select('_id').limit(500).lean();
        filter.userId = { $in: users.map(user => user._id) };
      }
      const [rows, total] = await Promise.all([
        Membership.find(filter).sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).populate('userId', 'name email').lean(),
        Membership.countDocuments(filter),
      ]);
      return res.json({ members: rows.filter(x => x.userId).map(x => ({ id: String(x._id), userId: String(x.userId._id), name: x.userId.name, email: x.userId.email, role: x.role, studentNames: x.studentNames })), total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  // School owners can link or correct pupils for a parent or staff member.
  // This affects only school membership visibility, never the user's global Chatify account.
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
      const registeredCount = await SchoolStudent.countDocuments({
        schoolId: req.params.schoolId, active: true,
        $expr: { $in: [{ $toLower: '$fullName' }, studentNames.map(name => name.toLowerCase())] },
      });
      if (registeredCount !== studentNames.length) {
        return res.status(400).json({ error: 'Every linked pupil must exist in the active school register before access is granted.' });
      }
      if (!mongoose.isValidObjectId(req.params.memberId)) {
        return res.status(400).json({ error: 'Invalid school member.' });
      }
      const member = await Membership.findOneAndUpdate(
        { _id: req.params.memberId, schoolId: req.params.schoolId, role: { $in: ['parent', 'staff'] }, active: true },
        { $set: { studentNames } },
        { new: true, runValidators: true }
      ).populate('userId', 'name email');
      if (!member) return res.status(404).json({ error: 'Active parent/staff membership was not found in this school.' });
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

  app.get('/api/schools/:schoolId/receipt-settings', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const school = await School.findById(req.params.schoolId).select('receiptStampDataUrl').lean();
      if (!school) return res.status(404).json({ error: 'School not found' });
      return res.json({ receiptStampDataUrl: school.receiptStampDataUrl || '' });
    } catch (error) { return next(error); }
  });

  app.put('/api/schools/:schoolId/receipt-settings', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const stampDataUrl = String(req.body?.receiptStampDataUrl || '').trim();
      if (stampDataUrl && (!/^data:image\/jpeg;base64,[A-Za-z0-9+/=\r\n]+$/.test(stampDataUrl) || stampDataUrl.length > 950000)) {
        return res.status(400).json({ error: 'Upload a JPEG school stamp smaller than 700 KB.' });
      }
      await School.updateOne({ _id: req.params.schoolId }, { $set: { receiptStampDataUrl: stampDataUrl } });
      return res.json({ receiptStampConfigured: Boolean(stampDataUrl), message: stampDataUrl ? 'School receipt stamp saved.' : 'School receipt stamp removed.' });
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
      const messageType = req.body?.messageType === 'conference' ? 'conference' : 'message';
      const startsAt = messageType === 'conference' ? new Date(req.body?.startsAt) : null;
      const endsAt = messageType === 'conference' ? new Date(req.body?.endsAt) : null;
      const location = String(req.body?.location || '').trim().slice(0, 300);
      const destination = resolveSchoolMessageDestination(req.schoolMembership.role, req.body?.audience, req.body?.recipientId);
      if (!body || body.length > 5000) return res.status(400).json({ error: 'Message must contain 1–5000 characters' });
      if (messageType === 'conference') {
        if (req.schoolMembership.role !== 'admin') return res.status(403).json({ error: 'Only school administrators can publish scheduled events' });
        if (!['all_parents', 'all_staff', 'all_school'].includes(String(req.body?.audience))) return res.status(400).json({ error: 'Choose parents, staff or the whole school as the event audience' });
        if (!String(req.body?.subject || '').trim() || String(req.body.subject).trim().length > 160 ||
            !Number.isFinite(startsAt.getTime()) || !Number.isFinite(endsAt.getTime()) ||
            startsAt <= new Date() || endsAt <= startsAt) {
          return res.status(400).json({ error: 'Enter an event title and valid future start/end times' });
        }
      }
      if (destination.error) {
        const status = ['parent', 'staff'].includes(req.schoolMembership.role) ? 403 : 400;
        return res.status(status).json({ error: destination.error });
      }
      const audience = destination.audience;
      const recipientId = destination.recipientId;
      if (audience === 'direct') {
        if (!mongoose.isValidObjectId(recipientId)) return res.status(400).json({ error: 'Choose a recipient' });
        const target = await Membership.findOne({ schoolId: req.params.schoolId, userId: recipientId, active: true });
        if (!target) return res.status(404).json({ error: 'Recipient is not a member of this school' });
        if (req.schoolMembership.role === 'parent' && !['admin','staff'].includes(target.role)) return res.status(403).json({ error: 'Parents may contact school administrators or staff only' });
      }
      const message = await SchoolMessage.create({
        schoolId: req.params.schoolId,
        senderId: req.user._id,
        recipientId: audience === 'direct' ? recipientId : undefined,
        audience,
        messageType,
        ...(messageType === 'conference' ? { startsAt, endsAt, location } : {}),
        subject: String(req.body?.subject || '').trim().slice(0,160),
        body,
      });
      return res.status(201).json({ message });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/messages', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const member = req.schoolMembership;
      const visibility = member.role === 'parent'
        ? { $or: [{ audience: 'all_parents' }, { audience: 'all_school' }, { senderId: req.user._id }, { recipientId: req.user._id }] }
        : member.role === 'staff'
          ? { $or: [{ audience: 'all_staff' }, { audience: 'all_school' }, { audience: 'school_inbox' }, { senderId: req.user._id }, { recipientId: req.user._id }] }
          : { $or: [{ audience: { $in: ['all_parents','all_staff','all_school','school_inbox'] } }, { senderId: req.user._id }, { recipientId: req.user._id }] };
      const page = pageOptions(req);
      const q = String(req.query.q || '').trim().slice(0, 120);
      const filter = { schoolId: req.params.schoolId, ...visibility };
      if (member.role === 'admin' && req.query.audience && ['direct','all_parents','all_staff','all_school','school_inbox'].includes(String(req.query.audience))) {
        filter.audience = String(req.query.audience);
      }
      if (q) {
        const safe = q.replace(/[.*+?^${}()|[\]\\]/g, (match) => `\\${match}`);
        const matchingUsers = await User.find({
          $or: [{ name: { $regex: safe, $options: 'i' } }, { email: { $regex: safe, $options: 'i' } }],
        }).select('_id').limit(200).lean();
        filter.$and = [{
          $or: [
            { subject: { $regex: safe, $options: 'i' } },
            { body: { $regex: safe, $options: 'i' } },
            { senderId: { $in: matchingUsers.map(user => user._id) } },
          ],
        }];
      }
      const [rows, total] = await Promise.all([
        SchoolMessage.find(filter).sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).populate('senderId', 'name email').lean(),
        SchoolMessage.countDocuments(filter),
      ]);
      const messages = rows.map(message => ({
        ...message,
        sender: message.senderId && typeof message.senderId === 'object'
          ? { id: String(message.senderId._id), name: message.senderId.name || message.senderId.email || 'School member', email: message.senderId.email || '' }
          : { id: String(message.senderId || ''), name: 'School member', email: '' },
        senderId: message.senderId && typeof message.senderId === 'object' ? String(message.senderId._id) : message.senderId,
      }));
      return res.json({ messages, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fee-structures', auth, requireRole('admin','staff'), async (req, res, next) => {
    try {
      const filter = { schoolId: req.params.schoolId };
      if (req.query.includeArchived !== 'true') filter.status = 'ACTIVE';
      const page = pageOptions(req);
      const [structures, total] = await Promise.all([
        SchoolFeeStructure.find(filter).sort({ className: 1, academicYear: -1, term: 1, version: -1 }).skip(page.skip).limit(page.limit).lean(),
        SchoolFeeStructure.countDocuments(filter),
      ]);
      return res.json({ structures, total, page: page.page, limit: page.limit });
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fee-structures', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const input = normalizeFeeStructureInput(req.body);
      if (!input) return res.status(400).json({ error: 'Enter a class, academic year, term, and 1–100 unique positive whole-KSh fee items.' });
      const classExists = await SchoolStudent.exists({ schoolId: req.params.schoolId, className: input.className, active: true });
      if (!classExists) return res.status(400).json({ error: 'Choose a class/grade that exists in this school’s active student register.' });
      const key = { schoolId: req.params.schoolId, className: input.className, academicYear: input.academicYear, term: input.term };
      const previousActive = await SchoolFeeStructure.findOne({ ...key, status: 'ACTIVE' }).lean();
      const latest = await SchoolFeeStructure.findOne(key).sort({ academicYear: -1, version: -1 }).lean();
      const version = Number(latest?.version || 0) + 1;
      if (previousActive) {
        await SchoolFeeStructure.updateOne({ _id: previousActive._id, status: 'ACTIVE' }, { $set: { status: 'ARCHIVED', archivedAt: new Date(), updatedBy: req.user._id } });
      }
      try {
        const structure = await SchoolFeeStructure.create({
          ...key, ...input, version, status: 'ACTIVE',
          createdBy: req.user._id, updatedBy: req.user._id,
        });
        return res.status(201).json({ structure, previousVersionArchived: Boolean(previousActive), note: 'This is a new version. Already-issued student charges are unchanged; issue this version only to students who do not already have a charge for this period.' });
      } catch (error) {
        // Restore the previous active version if a competing update wins the unique version/active transition.
        if (previousActive) {
          const anotherActive = await SchoolFeeStructure.exists({ ...key, status: 'ACTIVE' });
          if (!anotherActive) await SchoolFeeStructure.updateOne({ _id: previousActive._id }, { $set: { status: 'ACTIVE' }, $unset: { archivedAt: 1 } });
        }
        if (error?.code === 11000) return res.status(409).json({ error: 'Another administrator updated this fee structure concurrently. Refresh the list and retry.' });
        throw error;
      }
    } catch (error) { return next(error); }
  });

  app.post('/api/schools/:schoolId/fee-structures/:structureId/issue', auth, requireRole('admin'), async (req, res, next) => {
    try {
      if (!mongoose.isValidObjectId(req.params.structureId)) return res.status(400).json({ error: 'Invalid fee structure id' });
      const structure = await SchoolFeeStructure.findOne({ _id: req.params.structureId, schoolId: req.params.schoolId, status: 'ACTIVE' }).lean();
      if (!structure) return res.status(404).json({ error: 'Active fee structure not found in this school' });
      const enrolled = await SchoolStudent.find({ schoolId: req.params.schoolId, className: structure.className, active: true })
        .select('_id fullName admissionNumber className').lean();
      if (!enrolled.length) return res.status(409).json({ error: 'There are no active students in this class to receive charges.' });
      const operations = enrolled.map(student => ({
        updateOne: {
          filter: { schoolId: structure.schoolId, studentId: student._id, academicYear: structure.academicYear, term: structure.term },
          update: { $setOnInsert: {
            schoolId: structure.schoolId, studentId: student._id, studentName: student.fullName,
            admissionNumber: student.admissionNumber, className: student.className,
            academicYear: structure.academicYear, term: structure.term,
            items: structure.items, totalAmount: structure.totalAmount, credits: 0,
            structureId: structure._id, structureVersion: structure.version, issuedBy: req.user._id, issuedAt: new Date(),
          } },
          upsert: true,
        },
      }));
      const result = await SchoolStudentCharge.bulkWrite(operations, { ordered: false });
      return res.json({
        studentsInClass: enrolled.length,
        chargesCreated: result.upsertedCount || 0,
        existingChargesPreserved: enrolled.length - (result.upsertedCount || 0),
        note: 'Issuing is idempotent. Existing student charges are not overwritten by a later fee-structure version.',
      });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fee-balances', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const visibleStudents = await SchoolStudent.find(schoolStudentFilter(req)).select('_id').lean();
      const studentIds = visibleStudents.map(student => student._id);
      const chargeFilter = { schoolId: req.params.schoolId, studentId: { $in: studentIds } };
      if (req.query.academicYear) chargeFilter.academicYear = String(req.query.academicYear).trim().slice(0, 40);
      if (req.query.term) chargeFilter.term = String(req.query.term).trim().slice(0, 80);
      const charges = await SchoolStudentCharge.find(chargeFilter).sort({ className: 1, studentName: 1, academicYear: -1, term: 1 }).lean();
      const chargeIds = charges.map(charge => charge.studentId);
      const payments = chargeIds.length ? await FeePayment.find({
        schoolId: req.params.schoolId, studentId: { $in: chargeIds }, status: 'CONFIRMED',
      }).select('studentId academicYear term amount status').lean() : [];
      const byPeriod = new Map();
      for (const payment of payments) {
        const key = [String(payment.studentId), String(payment.academicYear || ''), String(payment.term || '')].join('|');
        byPeriod.set(key, [...(byPeriod.get(key) || []), payment]);
      }
      const balances = charges.map(charge => {
        const key = [String(charge.studentId), charge.academicYear, charge.term].join('|');
        const calculated = calculateSchoolFeeBalance({
          chargeAmount: charge.totalAmount,
          credits: charge.credits || 0,
          payments: byPeriod.get(key) || [],
        });
        return { ...charge, ...calculated, chargeId: String(charge._id) };
      });
      return res.json({ balances, total: balances.length });
    } catch (error) { return next(error); }
  });

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
    const school = await School.findById(payment.schoolId).select('name code receiptStampDataUrl paymentProfile.method').lean();
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


  // Promote a whole active class at year-end in one auditable operation.
  // Historical attendance, assessments, charges and receipts keep their original class snapshots.
  app.post('/api/schools/:schoolId/students/promote-class', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const fromClass = String(req.body?.fromClass || '').trim();
      const toClass = String(req.body?.toClass || '').trim();
      const academicYear = String(req.body?.academicYear || '').trim();
      if (!fromClass || fromClass.length > 80 || !toClass || toClass.length > 80 ||
          !academicYear || academicYear.length > 40 || fromClass.toLowerCase() === toClass.toLowerCase()) {
        return res.status(400).json({ error: 'Enter a valid current class, next class and academic year. The two classes must be different.' });
      }
      const schoolId = req.params.schoolId;
      const totalInClass = await SchoolStudent.countDocuments({ schoolId, active: true, className: fromClass });
      if (!totalInClass) return res.status(404).json({ error: 'No active pupils were found in that exact class name. Check the class spelling.' });
      const eligibleFilter = {
        schoolId, active: true, className: fromClass,
        $nor: [{ promotionHistory: { $elemMatch: { academicYear, fromClass } } }],
      };
      const eligible = await SchoolStudent.countDocuments(eligibleFilter);
      if (!eligible) {
        return res.status(409).json({ error: 'This class has already been promoted for that academic year. No pupils were changed.', totalInClass, promoted: 0 });
      }
      const promotedAt = new Date();
      const result = await SchoolStudent.updateMany(eligibleFilter, {
        $set: { className: toClass },
        $push: { promotionHistory: { fromClass, toClass, academicYear, promotedAt, promotedBy: req.user._id } },
      }, { runValidators: true });
      const promoted = Number(result.modifiedCount ?? result.nModified ?? 0);
      return res.json({
        success: true, fromClass, toClass, academicYear, promoted,
        alreadyProcessed: totalInClass - eligible,
        message: promoted ? `Promoted ${promoted} pupil(s) from ${fromClass} to ${toClass} for ${academicYear}.` : 'No pupils were changed.',
      });
    } catch (error) { return next(error); }
  });

  // Mark transferred pupils inactive rather than hard-deleting them. This removes
  // them from the active register while preserving financial and academic history.
  app.post('/api/schools/:schoolId/students/:studentId/transfer', auth, requireRole('admin'), async (req, res, next) => {
    try {
      const student = await SchoolStudent.findOneAndUpdate(
        { _id: req.params.studentId, schoolId: req.params.schoolId, active: true },
        { $set: { active: false, transferredOutAt: new Date(), transferredOutBy: req.user._id } },
        { new: true, runValidators: true },
      );
      if (!student) return res.status(404).json({ error: 'Active pupil not found. It may already have been transferred or removed.' });
      return res.json({ transferred: true, archived: true, id: String(student._id), transferredOutAt: student.transferredOutAt });
    } catch (error) { return next(error); }
  });

  // Financial fee records are intentionally not deletable; these routes cover
  // operational records and enforce school membership and role permissions.

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
      if (!studentName || studentName.length > 100 || !(req.schoolMembership.studentNames || []).some(name => String(name).trim().toLowerCase() === studentName.toLowerCase())) return res.status(403).json({ error: 'Choose a student linked to your parent account' });
      // A membership name alone is not proof of enrolment: fees can be requested only for a pupil in this school's active register.
      const registeredStudent = await SchoolStudent.findOne({
        schoolId: req.params.schoolId, active: true,
        $expr: { $eq: [{ $toLower: '$fullName' }, studentName.toLowerCase()] },
      }).select('_id fullName admissionNumber className').lean();
      if (!registeredStudent) return res.status(404).json({ error: 'This student is not in the school register yet. Contact the school office to link the correct registered pupil.' });
      if (!Number.isSafeInteger(amount) || amount < 1 || amount > 150000 || !term || term.length > 80) return res.status(400).json({ error: 'Enter a valid whole-KSh amount and school term' });
      const requestedAcademicYear = String(req.body?.academicYear || '').trim().slice(0, 40);
      let feeContext = { studentId: registeredStudent._id, className: registeredStudent.className, academicYear: requestedAcademicYear || 'unspecified' };
      const schoolHasFeeStructures = await SchoolFeeStructure.exists({ schoolId: req.params.schoolId, status: 'ACTIVE' });
      if (schoolHasFeeStructures) {
        const structureFilter = {
          schoolId: req.params.schoolId, className: registeredStudent.className, term, status: 'ACTIVE',
          ...(requestedAcademicYear ? { academicYear: requestedAcademicYear } : {}),
        };
        const structure = await SchoolFeeStructure.findOne(structureFilter).sort({ version: -1 }).lean();
        if (!structure) return res.status(409).json({ error: 'No active fee structure is configured for this student’s class and term. Ask the school administrator to configure it first.' });
        const charge = await SchoolStudentCharge.findOne({
          schoolId: req.params.schoolId, studentId: registeredStudent._id,
          academicYear: structure.academicYear, term,
        }).lean();
        if (!charge) return res.status(409).json({ error: 'Fees have not been issued to this student for the selected period. Ask the school administrator to issue the class fee structure.' });
        const confirmedPayments = await FeePayment.find({
          schoolId: req.params.schoolId, studentId: registeredStudent._id,
          academicYear: structure.academicYear, term, status: 'CONFIRMED',
        }).select('amount status').lean();
        const balance = calculateSchoolFeeBalance({ chargeAmount: charge.totalAmount, credits: charge.credits || 0, payments: confirmedPayments });
        if (balance.balance <= 0) return res.status(409).json({ error: 'There is no outstanding balance for this student and period.' });
        if (amount > balance.balance) return res.status(400).json({ error: 'Payment amount cannot exceed the current outstanding balance.', outstandingBalance: balance.balance });
        feeContext = { studentId: registeredStudent._id, className: registeredStudent.className, academicYear: structure.academicYear, chargeId: charge._id };
      }
      const school = await School.findById(req.params.schoolId).select('+paymentProfile.darajaConsumerKeyEnc +paymentProfile.darajaConsumerSecretEnc +paymentProfile.darajaPasskeyEnc').lean();
      const requestedMethod = String(req.body?.paymentMethod || school?.paymentProfile?.method || '');
      if (!['mpesa_paybill','mpesa_till','mpesa_send_money','bank'].includes(requestedMethod)) return res.status(400).json({ error: 'Choose one of the school’s configured fee payment methods.' });
      if (!school || (!school.paymentProfile?.method && requestedMethod !== 'mpesa_send_money')) return res.status(409).json({ error: 'This school has not configured payment details. Contact the school office before paying.' });
      if (requestedMethod === 'mpesa_send_money') {
        let officialPhone = normalizeMpesaPhone(school.officialPhone || '');
        if (!officialPhone) {
          const verification = await SchoolVerificationRequest.findOne({ schoolId: req.params.schoolId, status: 'APPROVED' }).select('officialPhone').sort({ reviewedAt: -1 }).lean();
          officialPhone = normalizeMpesaPhone(verification?.officialPhone || '');
        }
        if (!officialPhone) return res.status(409).json({ error: 'The school has not configured a verified M-Pesa phone number for Send Money.' });
        const paymentReference = 'SCH-' + randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
        const payment = await FeePayment.create({ paymentReference, schoolId: school._id, parentId: req.user._id, studentName, amount, term, ...feeContext, paymentMethod: requestedMethod, destinationNumber: officialPhone, status: 'PENDING_VERIFICATION' });
        return res.status(201).json({ payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status }, paymentDestination: { method: requestedMethod, officialPhone }, note: 'Send the amount to the school’s configured M-Pesa phone using Send Money. This record remains pending until school staff verify the M-Pesa receipt.' });
      }
      if (requestedMethod !== school.paymentProfile.method) return res.status(409).json({ error: 'The selected Till, Paybill or bank destination is not configured for this school.' });
      const isMpesa = ['mpesa_paybill','mpesa_till'].includes(requestedMethod);
      if (isMpesa && !phone) return res.status(400).json({ error: 'Enter a valid Kenyan M-Pesa phone number to receive the school fee STK prompt.' });
      if (isMpesa && (!school.paymentProfile.darajaConsumerKeyEnc || !school.paymentProfile.darajaConsumerSecretEnc || !school.paymentProfile.darajaPasskeyEnc)) return res.status(409).json({ error: 'This school has configured a Paybill/Till destination but has not completed its own Daraja STK Push setup. Contact the school administrator; no payment prompt has been sent.' });
      const paymentReference = 'SCH-' + randomUUID().replace(/-/g, '').slice(0, 12).toUpperCase();
      const destinationNumber = requestedMethod === 'mpesa_paybill' ? school.paymentProfile.paybillNumber : requestedMethod === 'mpesa_till' ? school.paymentProfile.tillNumber : undefined;
      const payment = await FeePayment.create({ paymentReference, schoolId: school._id, parentId: req.user._id, studentName, amount, term, ...feeContext, paymentMethod: requestedMethod, destinationNumber, ...(isMpesa ? { payerPhone: phone, status: 'PENDING_STK' } : { status: 'PENDING_VERIFICATION' }) });
      if (isMpesa) {
        try {
          const provider = providerForSchool(school);
          const refs = await provider.initiate({ paymentId: paymentReference, amount, phone, description: 'School fees', now: new Date() });
          payment.checkoutRequestId = refs.checkoutRequestId;
          payment.merchantRequestId = refs.merchantRequestId;
          await payment.save();
          return res.status(201).json({ payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status, checkoutRequestId: payment.checkoutRequestId }, paymentDestination: { method: requestedMethod, paybillNumber: school.paymentProfile.paybillNumber, tillNumber: school.paymentProfile.tillNumber }, note: 'A school-specific M-Pesa STK Push was submitted to Safaricom. The fee is not confirmed until the Daraja callback verifies the amount, payer phone and receipt number.' });
        } catch (error) {
          await FeePayment.updateOne({ _id: payment._id, status: 'PENDING_STK' }, { $set: { status: 'FAILED', callbackProcessedAt: new Date() } });
          console.error('School STK Push initiation failed', { schoolId: String(school._id), paymentReference, stage: error?.stage || 'configuration_or_unknown' });
          return res.status(503).json({ error: 'Safaricom could not start the school fee STK prompt. No receipt was issued. Check the school Daraja configuration and try again.' });
        }
      }
      return res.status(201).json({ payment: { paymentReference, schoolName: school.name, studentName, amount, term, status: payment.status }, paymentDestination: { method: requestedMethod, bankName: school.paymentProfile.bankName, accountNumber: school.paymentProfile.accountNumber }, note: 'Bank payment details provided. This record remains pending until school staff verify the bank transaction.' });
    } catch (error) { return next(error); }
  });

  app.get('/api/schools/:schoolId/fees', auth, requireRole('admin','staff','parent'), async (req, res, next) => {
    try {
      const filter = { schoolId: req.params.schoolId };
      if (['parent', 'staff'].includes(req.schoolMembership.role)) {
        const linkedNames = (req.schoolMembership.studentNames || []).map(name => String(name).trim().toLowerCase()).filter(Boolean);
        filter.$expr = { $in: [{ $toLower: '$studentName' }, linkedNames] };
      }
      // A parent sees only their own payments, and only for a linked child.
      if (req.schoolMembership.role === 'parent') filter.parentId = req.user._id;
      const page = pageOptions(req);
      const [payments, total] = await Promise.all([
        FeePayment.find(filter).select('-receiptHtml -receiptEmailSentTo -receiptEmailLastError -payerPhone -checkoutRequestId -merchantRequestId').sort({ createdAt: -1 }).skip(page.skip).limit(page.limit).lean(),
        FeePayment.countDocuments(filter),
      ]);
      // Guardian fields come from the authoritative student register; they are
      // included only after the fee query has already been school/role scoped.
      const paymentStudentNames = [...new Set(payments.map(payment => String(payment.studentName || '').trim().toLowerCase()).filter(Boolean))];
      const guardianRecords = paymentStudentNames.length
        ? await SchoolStudent.find({ schoolId: req.params.schoolId, $expr: { $in: [{ $toLower: '$fullName' }, paymentStudentNames] } }).select('fullName guardianName guardianPhone').lean()
        : [];
      const guardiansByName = new Map(guardianRecords.map(student => [String(student.fullName).trim().toLowerCase(), student]));
      const paymentChargeIds = [...new Set(payments.map(payment => payment.chargeId).filter(Boolean).map(String))];
      const [charges, confirmedChargePayments] = paymentChargeIds.length ? await Promise.all([
        SchoolStudentCharge.find({ _id: { $in: paymentChargeIds }, schoolId: req.params.schoolId }).lean(),
        FeePayment.find({ schoolId: req.params.schoolId, chargeId: { $in: paymentChargeIds }, status: 'CONFIRMED' }).select('chargeId amount status').lean(),
      ]) : [[], []];
      const chargesById = new Map(charges.map(charge => [String(charge._id), charge]));
      const chargePayments = new Map();
      for (const confirmedPayment of confirmedChargePayments) {
        const key = String(confirmedPayment.chargeId);
        chargePayments.set(key, [...(chargePayments.get(key) || []), confirmedPayment]);
      }
      const paymentsWithGuardians = payments.map(payment => {
        const guardian = guardiansByName.get(String(payment.studentName || '').trim().toLowerCase());
        const method = payment.paymentMethod || payment.method;
        const charge = payment.chargeId ? chargesById.get(String(payment.chargeId)) : null;
        const balance = charge ? calculateSchoolFeeBalance({
          chargeAmount: charge.totalAmount,
          credits: charge.credits || 0,
          payments: chargePayments.get(String(charge._id)) || [],
        }) : null;
        return {
          ...payment,
          schoolName: undefined,
          paymentMethodLabel: schoolPaymentMethodLabel(method),
          guardianName: guardian?.guardianName || '',
          guardianPhone: guardian?.guardianPhone || '',
          ...(balance ? {
            totalFeeDue: balance.chargeAmount,
            outstandingBalance: balance.balance,
            confirmedPaidForTerm: balance.confirmedPaid,
            feeBalanceStatus: balance.status,
          } : { totalFeeDue: null, outstandingBalance: null, feeBalanceStatus: 'NOT_CONFIGURED' }),
        };
      });
      const school = await School.findById(req.params.schoolId).select('name code officialPhone receiptStampDataUrl paymentProfile.method paymentProfile.paybillNumber paymentProfile.tillNumber paymentProfile.bankName paymentProfile.accountNumber paymentProfile.darajaConfiguredAt').lean();
      const profile = school?.paymentProfile;
      let officialPhone = school?.officialPhone || '';
      if (!officialPhone) {
        const verification = await SchoolVerificationRequest.findOne({ schoolId: req.params.schoolId, status: 'APPROVED' })
          .select('officialPhone').sort({ reviewedAt: -1 }).lean();
        officialPhone = verification?.officialPhone || '';
      }
      const paymentOptions = {
        schoolName: school?.name || 'School',
        officialPhone,
        configured: Boolean(profile?.method),
        method: profile?.method || null,
        paybillNumber: profile?.method === 'mpesa_paybill' ? profile.paybillNumber : null,
        tillNumber: profile?.method === 'mpesa_till' ? profile.tillNumber : null,
        bankName: profile?.method === 'bank' ? profile.bankName : null,
        accountNumber: profile?.method === 'bank' ? profile.accountNumber : null,
        darajaConfigured: Boolean(profile?.darajaConfiguredAt),
      };
      return res.json({ payments: paymentsWithGuardians, paymentOptions, total, page: page.page, limit: page.limit });
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
      const school = await School.findById(req.params.schoolId).select('name code receiptStampDataUrl paymentProfile.method').lean();
      let balanceDetails = {};
      if (confirmed.chargeId) {
        const charge = await SchoolStudentCharge.findOne({
          _id: confirmed.chargeId, schoolId: req.params.schoolId,
        }).lean();
        if (charge) {
          const confirmedPayments = await FeePayment.find({
            schoolId: req.params.schoolId, chargeId: charge._id, status: 'CONFIRMED',
          }).select('amount status').lean();
          const calculated = calculateSchoolFeeBalance({
            chargeAmount: charge.totalAmount,
            credits: charge.credits || 0,
            payments: confirmedPayments,
          });
          balanceDetails = { chargeAmount: calculated.chargeAmount, balance: calculated.balance };
        }
      }
      const receiptHtml = renderSchoolReceipt(school, {
        ...confirmed.toObject(), ...balanceDetails,
      });
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
      const school = await School.findById(payment.schoolId).select('name code receiptStampDataUrl paymentProfile.method').lean();
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
      // Chatify monetizes school workspaces through setup and subscription fees.
      // Do not initiate a percentage-based second STK prompt for school-fee payments.
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
      if (['parent', 'staff'].includes(req.schoolMembership.role)) {
        const linkedNames = (req.schoolMembership.studentNames || []).map(name => String(name).trim().toLowerCase()).filter(Boolean);
        if (!linkedNames.includes(String(payment.studentName || '').trim().toLowerCase())) {
          return res.status(403).json({ error: 'This receipt is not for a student linked to your school membership.' });
        }
      }
      if (payment.status !== 'CONFIRMED') return res.status(409).json({ error: 'Receipt unavailable until the school verifies payment' });
      const school = await School.findById(req.params.schoolId).select('name code receiptStampDataUrl paymentProfile.method').lean();
      const receipt = renderSchoolReceipt(school, payment);
      res.setHeader('Content-Type', 'text/html; charset=utf-8');
      res.setHeader('Content-Disposition', 'attachment; filename="school-fee-receipt-' + payment.paymentReference + '.html"');
      return res.send(receipt);

    } catch (error) { return next(error); }
  });
}
