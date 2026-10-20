import 'dotenv/config';
import { createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import mongoose from 'mongoose';
import bcrypt from 'bcryptjs';
import { nextDemoSessionVersion, resolveDemoSeedConfig } from './seedConfig.js';
import { registerBusinessRoutes } from './business.js';
import { registerSchoolRoutes } from './school.js';

const DEMO_KEY = 'chatify-demo-v1';
const accounts = [
  { key: 'platform-admin', name: 'Demo Platform Admin', email: 'admin@demo.chatify.test', role: 'admin', module: 'Platform', association: 'Platform administrator' },
  { key: 'alice', name: 'Alice Mwangi', email: 'alice@demo.chatify.test', role: 'user', module: 'Chats', association: 'Direct and group conversations' },
  { key: 'brian', name: 'Brian Otieno', email: 'brian@demo.chatify.test', role: 'user', module: 'Chats', association: 'Direct conversation and saved contact' },
  { key: 'business-owner', name: 'Nia Kamau', email: 'nia@demo.chatify.test', role: 'user', module: 'Business and Stores', association: "Owner, Makena's Market" },
  { key: 'business-staff', name: 'Sam Wekesa', email: 'sam@demo.chatify.test', role: 'user', module: 'Business and Stores', association: "Manager, Makena's Market; owner, Jirani Creative Studio" },
  { key: 'school-admin', name: 'Grace Achieng', email: 'grace@demo.chatify.test', role: 'user', module: 'Schools', association: 'Administrator and workspace owner, Lakeview Community School' },
  { key: 'teacher', name: 'Peter Maina', email: 'peter@demo.chatify.test', role: 'user', module: 'Schools', association: 'Staff member, Lakeview Community School' },
  { key: 'parent', name: 'Miriam Njeri', email: 'miriam@demo.chatify.test', role: 'user', module: 'Schools', association: 'Parent member and guardian, Lakeview Community School' },
];

function stableId(key) {
  return new mongoose.Types.ObjectId(createHash('sha256').update(`${DEMO_KEY}:${key}`).digest('hex').slice(0, 24));
}

function registerAppModels() {
  const O = mongoose.Schema.Types.ObjectId;
  const model = (name, schema) => mongoose.models[name] || mongoose.model(name, schema);
  const User = model('User', new mongoose.Schema({
    name: { type: String, required: true, trim: true, maxlength: 80 }, email: { type: String, unique: true, lowercase: true, trim: true, required: true },
    sessionVersion: { type: Number, default: 0 }, phone: String, encryptionPublicKey: { type: String, select: true }, passwordHash: { type: String, required: true },
    emailVerified: { type: Boolean, default: true }, emailVerificationTokenHash: String, emailVerificationExpiresAt: Date, profileImage: String,
    status: { type: String, default: 'active' }, role: { type: String, enum: ['user', 'admin'], default: 'user', index: true }, demoSeedKey: { type: String, select: false },
    lastSeen: Date, privacy: { lastSeen: { type: Boolean, default: true }, readReceipts: { type: Boolean, default: true } }, blockedUsers: [O], pushTokens: { type: [String], default: [] },
    notificationPreferences: { messages: { type: Boolean, default: true }, mentions: { type: Boolean, default: true }, memories: { type: Boolean, default: true } },
  }, { timestamps: true }));
  const Conversation = model('Conversation', new mongoose.Schema({
    type: { type: String, enum: ['direct', 'group'], default: 'direct' }, participants: [{ type: O, ref: 'User' }], hiddenFor: { type: [O], default: [] },
    directKey: { type: String, unique: true, sparse: true }, title: String, description: String, image: String, admins: [O], lastMessage: { text: String, senderId: O, createdAt: Date },
  }, { timestamps: true }));
  const Message = model('Message', new mongoose.Schema({
    conversationId: { type: O, index: true }, senderId: O, text: { type: String, trim: true, maxlength: 5000 }, encryptedPayload: { type: String, select: true },
    encryptionVersion: { type: Number, enum: [1] }, messageType: { type: String, enum: ['text', 'image', 'file'], default: 'text' }, mediaUrl: String, replyTo: O,
    reactions: [{ userId: O, emoji: String }], hiddenFor: [O], deliveredTo: [O], readBy: [O], expiryType: { type: String, enum: ['NONE', 'AFTER_READ', 'AFTER_TIME', 'AFTER_REPLY'], default: 'NONE' },
    expiresAt: Date, expiredAt: Date, deletedAt: Date,
  }, { timestamps: true }));
  const SavedContact = model('SavedContact', new mongoose.Schema({ userId: { type: O, required: true, index: true }, contactUserId: { type: O, ref: 'User', required: true, index: true }, nameOverride: { type: String, trim: true, maxlength: 80 } }, { timestamps: true }));
  SavedContact.schema.index({ userId: 1, contactUserId: 1 }, { unique: true });
  const Memory = model('Memory', new mongoose.Schema({ userId: { type: O, index: true }, conversationId: O, personId: { type: O, index: true }, personName: { type: String, trim: true, maxlength: 80 }, type: { type: String, enum: ['EVENT', 'PAYMENT', 'PLACE', 'TASK', 'NOTE', 'OTHER'] }, title: String, description: String, date: Date, time: String, location: String, sourceMessageId: O, completed: { type: Boolean, default: false } }, { timestamps: true }));

  const noRoute = () => {};
  const app = { get: noRoute, post: noRoute, put: noRoute, patch: noRoute, delete: noRoute };
  registerBusinessRoutes({ app, auth: noRoute, mongoose, User, Conversation, Payment: undefined, io: null, mpesaProvider: null, startScheduler: false });
  registerSchoolRoutes({ app, auth: noRoute, mongoose, User, emailProvider: null });
  return { User, Conversation, Message, SavedContact, Memory };
}

function record(Model, key, values) {
  return { key, Model, id: stableId(key), values };
}

function makeData(models, people) {
  const { Conversation, Message, SavedContact, Memory } = models;
  const byKey = Object.fromEntries(people.map(person => [person.key, person.user]));
  const alice = byKey.alice, brian = byKey.brian, owner = byKey['business-owner'], staff = byKey['business-staff'];
  const schoolAdmin = byKey['school-admin'], teacher = byKey.teacher, parent = byKey.parent;
  const directId = stableId('chat:direct'), groupId = stableId('chat:group');
  const directKey = [String(alice._id), String(brian._id)].sort().join(':');
  const message1 = stableId('chat:direct:message:1'), message2 = stableId('chat:direct:message:2');
  const catalogKeys = ['woven-basket', 'tea-gift-box', 'delivery-service', 'brand-review', 'honey-jar', 'maasai-coasters', 'studio-workshop'];
  const productIds = catalogKeys.map(key => stableId(`catalog:${key}`));
  const customerId = stableId('customer:amina'), orderId = stableId('document:order');
  const storeId = stableId('business:makena-market'), studioId = stableId('business:jirani-studio');
  const schoolId = stableId('school:lakeview');
  const yesterday = new Date('2026-10-19T00:00:00.000Z');
  const records = [
    record(Conversation, 'chat:direct', { _id: directId, type: 'direct', directKey, participants: [alice._id, brian._id], lastMessage: { text: 'The library works. See you then!', senderId: brian._id, createdAt: new Date('2026-10-20T08:30:00.000Z') } }),
    record(Conversation, 'chat:group', { _id: groupId, type: 'group', participants: [alice._id, brian._id, staff._id], title: 'Community Project', description: 'Planning and project updates', admins: [alice._id], lastMessage: { text: 'I will share the draft this afternoon.', senderId: staff._id, createdAt: new Date('2026-10-20T09:10:00.000Z') } }),
    record(Message, 'chat:direct:message:1', { _id: message1, conversationId: directId, senderId: alice._id, text: "Let's meet at the library tomorrow at 2 PM to discuss the project.", expiryType: 'NONE', readBy: [alice._id], deliveredTo: [brian._id] }),
    record(Message, 'chat:direct:message:2', { _id: message2, conversationId: directId, senderId: brian._id, text: 'The library works. See you then!', expiryType: 'NONE', readBy: [brian._id, alice._id], deliveredTo: [alice._id], replyTo: message1, reactions: [{ userId: alice._id, emoji: '👍' }] }),
    record(Message, 'chat:group:message:1', { _id: stableId('chat:group:message:1'), conversationId: groupId, senderId: staff._id, text: 'I will share the draft this afternoon.', expiryType: 'NONE', readBy: [staff._id], deliveredTo: [alice._id, brian._id] }),
    record(SavedContact, 'contact:alice:brian', { _id: stableId('contact:alice:brian'), userId: alice._id, contactUserId: brian._id }),
    record(SavedContact, 'contact:brian:alice', { _id: stableId('contact:brian:alice'), userId: brian._id, contactUserId: alice._id }),
    record(Memory, 'memory:library-meeting', { _id: stableId('memory:library-meeting'), userId: alice._id, personId: brian._id, personName: brian.name, conversationId: directId, sourceMessageId: message1, type: 'EVENT', title: 'Project Meeting', description: 'Discuss the community project', date: new Date('2026-10-21T00:00:00.000Z'), time: '2 PM', location: 'Library', completed: false }),
  ];

  const Organization = mongoose.model('BusinessOrganization'), CatalogItem = mongoose.model('BusinessCatalogItem');
  const Customer = mongoose.model('BusinessCustomer'), Document = mongoose.model('BusinessDocument'), Task = mongoose.model('BusinessTask');
  const Case = mongoose.model('BusinessCase'), Supplier = mongoose.model('BusinessSupplier'), Workflow = mongoose.model('BusinessWorkflow');
  const InboxAssignment = mongoose.model('BusinessInboxAssignment'), TradeRequest = mongoose.model('BusinessTradeRequest');
  const storeData = { _id: storeId, name: "Makena's Market", slug: 'demo-makenas-market', ownerId: owner._id, industry: 'retail', description: 'A neighbourhood shop for Kenyan crafts and gifts.', email: owner.email, phone: '+254700000101', country: 'KE', currency: 'KES', timezone: 'Africa/Nairobi', settings: { storefrontPublished: true }, branches: [{ _id: stableId('branch:makena:westlands'), name: 'Westlands Pickup Point', address: 'Westlands, Nairobi', phone: '+254700000101', active: true }, { _id: stableId('branch:makena:karen'), name: 'Karen Market Stall', address: 'Karen, Nairobi', phone: '+254700000102', active: true }], members: [{ userId: owner._id, role: 'owner' }, { userId: staff._id, role: 'manager' }] };
  const studioData = { _id: studioId, name: 'Jirani Creative Studio', slug: 'demo-jirani-studio', ownerId: staff._id, industry: 'consulting', description: 'A small team helping local organizations with design and communications.', email: staff.email, country: 'KE', currency: 'KES', settings: { storefrontPublished: true }, branches: [{ _id: stableId('branch:jirani:nairobi'), name: 'Nairobi Studio', address: 'Kilimani, Nairobi', active: true }], members: [{ userId: staff._id, role: 'owner' }] };
  records.push(record(Organization, 'business:makena-market', storeData), record(Organization, 'business:jirani-studio', studioData));
  const catalog = [
    { name: 'Handwoven Sisal Basket', sku: 'DEMO-BASKET-01', category: 'Home and craft', description: 'Handwoven natural-fibre storage basket.', price: 2400, stock: 18, lowStockAt: 4, images: ['https://images.unsplash.com/photo-1590736969955-71cc94901144'], organizationId: storeId },
    { name: 'Kenyan Tea Gift Box', sku: 'DEMO-TEA-01', category: 'Gifts', description: 'A gift selection of locally grown tea.', price: 1850, stock: 24, lowStockAt: 5, images: ['https://images.unsplash.com/photo-1544787219-7f47ccb76574'], organizationId: storeId },
    { name: 'Delivery and Gift Wrapping', sku: 'DEMO-SERVICE-01', category: 'Services', description: 'Local delivery with reusable gift wrapping.', price: 350, stock: 0, lowStockAt: 0, type: 'service', organizationId: storeId },
    { name: 'Brand Review Session', sku: 'DEMO-STUDIO-01', category: 'Consulting', description: 'A one-hour brand and communications review.', price: 5000, stock: 0, lowStockAt: 0, type: 'service', organizationId: studioId },
    { name: 'Coastal Forest Honey', sku: 'DEMO-HONEY-01', category: 'Food and pantry', description: 'A 500 g jar of locally sourced wildflower honey.', price: 950, stock: 3, lowStockAt: 6, images: ['https://images.unsplash.com/photo-1587049352851-8d4e89133924'], organizationId: storeId },
    { name: 'Maasai Bead Coasters', sku: 'DEMO-COASTER-01', category: 'Home and craft', description: 'Set of four colourful hand-beaded coasters.', price: 1200, stock: 12, lowStockAt: 3, images: ['https://images.unsplash.com/photo-1578500494198-246f612d3b3d'], organizationId: storeId },
    { name: 'Small Business Brand Workshop', sku: 'DEMO-WORKSHOP-01', category: 'Consulting', description: 'A facilitated two-hour brand planning workshop.', price: 8500, stock: 0, lowStockAt: 0, type: 'service', organizationId: studioId },
  ];
  catalog.forEach((item, index) => records.push(record(CatalogItem, `catalog:${catalogKeys[index]}`, { _id: productIds[index], type: 'product', currency: 'KES', active: true, ...item })));
  const customerId2 = stableId('customer:baraka');
  const customerId3 = stableId('customer:zawadi');
  records.push(
    record(Customer, 'customer:amina', { _id: customerId, organizationId: storeId, name: 'Amina Hassan', email: 'amina.customer@example.test', phone: '+254700000202', company: 'Amina Home', tags: ['demo', 'retail'], source: 'manual', messagingConsent: false }),
    record(Customer, 'customer:baraka', { _id: customerId2, organizationId: storeId, name: 'Baraka Muli', email: 'baraka.customer@example.test', phone: '+254700000204', company: 'Muli Guest House', tags: ['demo', 'hospitality'], source: 'referral', messagingConsent: false }),
    record(Customer, 'customer:zawadi', { _id: customerId3, organizationId: studioId, name: 'Zawadi Wanjiku', email: 'zawadi.customer@example.test', phone: '+254700000205', company: 'Kijani Community Initiative', tags: ['demo', 'consulting'], source: 'manual', messagingConsent: false }),
    record(Document, 'document:order', { _id: orderId, organizationId: storeId, customerId, type: 'order', number: 'DEMO-ORD-1001', status: 'sent', items: [{ catalogItemId: productIds[0], name: 'Handwoven Sisal Basket', quantity: 1, unitPrice: 2400, lineTotal: 2400 }, { catalogItemId: productIds[2], name: 'Delivery and Gift Wrapping', quantity: 1, unitPrice: 350, lineTotal: 350 }], subtotal: 2750, taxRate: 0, taxMode: 'none', tax: 0, total: 2750, paidAmount: 0, currency: 'KES', notes: 'Sample storefront order; no payment was initiated.', createdBy: owner._id }),
    record(Document, 'document:invoice', { _id: stableId('document:invoice'), organizationId: storeId, customerId: customerId2, type: 'invoice', number: 'DEMO-INV-1001', status: 'sent', items: [{ catalogItemId: productIds[1], name: 'Kenyan Tea Gift Box', quantity: 2, unitPrice: 1850, lineTotal: 3700 }], subtotal: 3700, taxRate: 0, taxMode: 'none', tax: 0, total: 3700, paidAmount: 0, currency: 'KES', dueDate: new Date('2026-11-05T00:00:00.000Z'), notes: 'Sample unpaid invoice; no payment has been recorded.', createdBy: owner._id }),
    record(Document, 'document:quote', { _id: stableId('document:quote'), organizationId: studioId, customerId: customerId3, type: 'quote', number: 'DEMO-QUO-1001', status: 'sent', items: [{ catalogItemId: productIds[3], name: 'Brand Review Session', quantity: 1, unitPrice: 5000, lineTotal: 5000 }], subtotal: 5000, taxRate: 0, taxMode: 'none', tax: 0, total: 5000, paidAmount: 0, currency: 'KES', notes: 'Sample consulting quote, not yet accepted.', createdBy: staff._id }),
    record(Task, 'business:task:follow-up', { _id: stableId('business:task:follow-up'), organizationId: storeId, title: 'Follow up on sample order', description: 'Confirm preferred delivery day with the customer.', type: 'follow_up', status: 'open', priority: 'normal', dueAt: new Date('2026-10-21T06:00:00.000Z'), assignedTo: staff._id, customerId, documentId: orderId, createdBy: owner._id }),
    record(Task, 'business:task:restock', { _id: stableId('business:task:restock'), organizationId: storeId, title: 'Restock coastal forest honey', description: 'Contact the supplier and replenish the low-stock honey jars.', type: 'maintenance', status: 'in_progress', priority: 'high', assignedTo: staff._id, createdBy: owner._id }),
    record(Task, 'business:task:brand-review', { _id: stableId('business:task:brand-review'), organizationId: studioId, title: 'Prepare brand review notes', description: 'Review the customer brief and prepare workshop materials.', type: 'task', status: 'open', priority: 'normal', dueAt: new Date('2026-10-22T12:00:00.000Z'), assignedTo: staff._id, customerId: customerId3, createdBy: staff._id }),
    record(Case, 'business:case:delivery', { _id: stableId('business:case:delivery'), organizationId: storeId, customerId, conversationId: groupId, title: 'Confirm delivery arrangements', description: 'Customer asked whether the basket can arrive before the weekend.', status: 'waiting_customer', priority: 'normal', assignees: [owner._id, staff._id], updates: [{ authorId: staff._id, body: 'Shared delivery options and awaiting the preferred day.', createdAt: new Date('2026-10-20T07:00:00.000Z') }] }),
    record(Supplier, 'business:supplier:honey', { _id: stableId('business:supplier:honey'), organizationId: storeId, name: 'Tana Valley Apiaries', email: 'orders@tana-apiaries.example.test', phone: '+254700000206', address: 'Garissa County, Kenya', notes: 'Sample supplier record.', reliabilityNotes: 'Demo record; confirm availability before placing a real order.', active: true }),
    record(Workflow, 'business:workflow:order-follow-up', { _id: stableId('business:workflow:order-follow-up'), organizationId: storeId, name: 'New order follow-up preview', description: 'Preview creating a follow-up task after a new order.', trigger: 'order_created', enabled: false, actions: [{ actionType: 'create_task', config: { title: 'Review new order' } }], runs: [{ status: 'test_only', triggerData: { documentNumber: 'DEMO-ORD-1001' }, result: { wouldRun: ['create_task'], executed: false }, ranAt: new Date('2026-10-20T08:00:00.000Z'), ranBy: owner._id }] }),
    record(InboxAssignment, 'business:inbox:community-project', { _id: stableId('business:inbox:community-project'), organizationId: studioId, conversationId: groupId, assignedTo: staff._id, status: 'open', priority: 'normal', handoverNote: 'Sample shared-inbox assignment for the project conversation.', lastHandoverBy: owner._id, lastHandoverAt: new Date('2026-10-20T08:15:00.000Z'), customerId: customerId3 }),
    record(TradeRequest, 'business:trade:packaging', { _id: stableId('business:trade:packaging'), organizationId: storeId, buyerId: owner._id, supplierId: stableId('business:supplier:honey'), title: 'Reusable gift packaging', quantity: 100, budget: 18000, currency: 'KES', details: 'Sample sourcing request; no purchase has been placed.', status: 'open' }),
  );

  const School = mongoose.model('SchoolWorkspace'), Membership = mongoose.model('SchoolMembership'), Student = mongoose.model('SchoolStudent');
  const Attendance = mongoose.model('SchoolAttendance'), Assessment = mongoose.model('SchoolAssessment'), SchoolMessage = mongoose.model('SchoolMessage');
  const Conference = mongoose.model('SchoolConference'), FeePayment = mongoose.model('SchoolFeePayment');
  const names = ['Amani Njeri', 'Leo Njeri', 'Imani Njeri', 'Taji Njeri', 'Zuri Njeri', 'Kito Njeri'];
  records.push(record(School, 'school:lakeview', { _id: schoolId, name: 'Lakeview Community School', code: 'DEMO-LAKEVIEW', createdBy: schoolAdmin._id }));
  for (const [key, user, role, studentNames] of [
    ['admin', schoolAdmin, 'admin', []], ['teacher', teacher, 'staff', names], ['parent', parent, 'parent', names],
  ]) records.push(record(Membership, `school:member:${key}`, { _id: stableId(`school:member:${key}`), schoolId, userId: user._id, role, studentNames, active: true }));
  const students = [
    { admissionNumber: 'DEMO-001', fullName: names[0], className: 'Grade 4 East', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
    { admissionNumber: 'DEMO-002', fullName: names[1], className: 'Grade 2 West', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
    { admissionNumber: 'DEMO-003', fullName: names[2], className: 'Grade 4 East', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
    { admissionNumber: 'DEMO-004', fullName: names[3], className: 'Grade 2 West', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
    { admissionNumber: 'DEMO-005', fullName: names[4], className: 'Grade 6 North', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
    { admissionNumber: 'DEMO-006', fullName: names[5], className: 'Grade 6 North', guardianName: parent.name, guardianPhone: '+254700000303', guardianEmail: parent.email },
  ];
  students.forEach((student, i) => {
    const studentId = stableId(`school:student:${i}`);
    records.push(record(Student, `school:student:${i}`, { _id: studentId, schoolId, ...student, active: true }));
    const status = ['present', 'late', 'present', 'absent', 'present', 'excused'][i];
    records.push(record(Attendance, `school:attendance:${i}`, { _id: stableId(`school:attendance:${i}`), schoolId, studentId, studentName: student.fullName, admissionNumber: student.admissionNumber, className: student.className, date: yesterday, status, note: status === 'absent' ? 'Parent notified.' : '', markedBy: teacher._id }));
    for (const [subjectIndex, subject] of ['Mathematics', 'English'].entries()) {
      const score = 72 + ((i * 7 + subjectIndex * 9) % 25);
      const assessmentKey = subjectIndex === 0 ? `school:assessment:${i}` : `school:assessment:${i}:${subjectIndex}`;
      records.push(record(Assessment, assessmentKey, { _id: stableId(assessmentKey), schoolId, studentId, studentName: student.fullName, admissionNumber: student.admissionNumber, className: student.className, subject, assessment: 'October class exercise', term: 'Term 3, 2026', score, outOf: 100, teacherNote: 'Sample academic record.', recordedBy: teacher._id }));
    }
  });
  records.push(
    record(SchoolMessage, 'school:announcement', { _id: stableId('school:announcement'), schoolId, senderId: schoolAdmin._id, audience: 'all_school', subject: 'Term 3 family meeting', body: 'Families are invited to the term meeting on Friday at 3 PM.' }),
    record(SchoolMessage, 'school:staff-message', { _id: stableId('school:staff-message'), schoolId, senderId: schoolAdmin._id, audience: 'all_staff', subject: 'Grade team planning', body: 'Please review the October assessment results before the Friday planning meeting.' }),
    record(SchoolMessage, 'school:parent-message', { _id: stableId('school:parent-message'), schoolId, senderId: schoolAdmin._id, audience: 'all_parents', subject: 'Learner progress and family meeting', body: 'A progress update is available for your linked learners. Please contact the school office if you need assistance.' }),
    record(SchoolMessage, 'school:parent-inbox', { _id: stableId('school:parent-inbox'), schoolId, senderId: parent._id, recipientId: schoolAdmin._id, audience: 'direct', subject: 'Question about the family meeting', body: 'Could you please confirm whether both learners should attend the Friday meeting?' }),
    record(SchoolMessage, 'school:staff-inbox', { _id: stableId('school:staff-inbox'), schoolId, senderId: teacher._id, recipientId: schoolAdmin._id, audience: 'direct', subject: 'Grade 4 assessment update', body: 'The Grade 4 October exercises have been recorded and are ready for review.' }),
    record(Conference, 'school:conference', { _id: stableId('school:conference'), schoolId, createdBy: schoolAdmin._id, title: 'Term 3 family meeting', agenda: 'Review learner progress and upcoming activities.', startsAt: new Date('2026-10-23T12:00:00.000Z'), endsAt: new Date('2026-10-23T13:00:00.000Z'), audience: 'all_parents', location: 'School hall' }),
    record(Conference, 'school:staff-conference', { _id: stableId('school:staff-conference'), schoolId, createdBy: schoolAdmin._id, title: 'Grade team planning', agenda: 'Review class attendance and coordinate the next learning activities.', startsAt: new Date('2026-10-22T13:00:00.000Z'), endsAt: new Date('2026-10-22T14:00:00.000Z'), audience: 'all_staff', location: 'Staff room' }),
    record(FeePayment, 'school:fee:demo-pending', { _id: stableId('school:fee:demo-pending'), paymentReference: 'DEMO-FEE-1001', schoolId, parentId: parent._id, studentName: names[0], amount: 12500, term: 'Term 3, 2026', status: 'PENDING_VERIFICATION', payerPhone: '+254700000303' }),
  );
  return { records, people, ids: { storeId, studioId, schoolId, directId, groupId } };
}

function renderRegister(people, outcomes, passwordVerified, loginResults = new Map()) {
  const rows = people.map(person => `| ${person.name} | ${person.email} | — | ${person.role} | ${person.module}: ${person.association} | active | ${outcomes.get(person.key) || 'not run'} | ${loginResults.get(person.key) || (passwordVerified ? 'bcrypt verifier passed; login API not exercised' : 'not verified')} |`).join('\n');
  const apiVerified = loginResults.size === people.length && [...loginResults.values()].every(result => result === 'HTTP login passed');
  const verificationNote = apiVerified
    ? 'Every listed account passed the local HTTP login endpoint; the seed checked active status, expected platform role, returned account identity and token presence without logging token values.'
    : 'The seed verifies stored hashes with the same bcrypt library used by the server. This does not exercise the HTTP login route. API login verification must be recorded separately in an isolated running demo environment.';
  return `# Demo account register\n\nGenerated by npm run seed for the explicitly selected demo database.\n\nAll eligible accounts use the password configured in SEED_DEMO_PASSWORD (or the legacy DEMO_SEED_PASSWORD variable). This is a shared demo/testing password; never use it for production accounts. The password and hashes are not included here.\n\n| Display name | Login email | Username | Platform role | Module / organization association | Status | Seed result | Authentication verification |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n${rows}\n\n${verificationNote} The school model supports administrator, staff and parent memberships; students are student records, not login accounts in the current application.\n`;
}

async function verifyLoginApi(passwordValue) {
  const base = new URL(process.env.CHATIFY_DEMO_API_URL || 'http://127.0.0.1:5000');
  if (base.protocol !== 'http:' || !['127.0.0.1', 'localhost', '::1'].includes(base.hostname)) {
    throw new Error('CHATIFY_DEMO_API_URL must use HTTP on localhost so demo credentials are not sent to a remote server');
  }
  const results = new Map();
  for (const account of accounts) {
    try {
      const response = await fetch(new URL('/api/auth/login', base), {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email: account.email, password: passwordValue }), signal: AbortSignal.timeout(5000),
      });
      const body = await response.json();
      const passed = response.ok && body.user?.email === account.email && body.user?.role === account.role && body.user?.status === 'active' && typeof body.token === 'string';
      results.set(account.key, passed ? 'HTTP login passed' : `HTTP login failed (${response.status})`);
    } catch {
      results.set(account.key, 'HTTP login unverified (API unavailable)');
    }
  }
  return results;
}

async function main() {
  const config = resolveDemoSeedConfig(process.env, process.argv.slice(2));
  if (config.dryRun) {
    console.log(JSON.stringify({ mode: 'dry-run', databaseName: config.databaseName, plannedAccounts: accounts.length, plannedModules: ['Chats', 'Business', 'Stores (Business catalogue/storefront)', 'Schools'], message: 'No database connection or writes were made.' }, null, 2));
    return;
  }

  await mongoose.connect(config.uri, { serverSelectionTimeoutMS: 10000 });
  try {
    const models = registerAppModels();
    const managed = await Promise.all(accounts.map(async person => {
      const existing = await models.User.findOne({ email: person.email }).select('+demoSeedKey');
      if (existing && existing.demoSeedKey !== DEMO_KEY) throw new Error(`Refusing to modify an account not managed by this demo seed: ${person.email}`);
      return { ...person, existing, user: existing };
    }));
    const passwordHash = await bcrypt.hash(config.passwordValue, 12);
    const results = new Map();
    for (const person of managed) {
      const values = { name: person.name, email: person.email, passwordHash, emailVerified: true, profileImage: `https://api.dicebear.com/9.x/initials/svg?seed=${encodeURIComponent(person.name)}`, status: 'active', role: person.role, demoSeedKey: DEMO_KEY };
      if (person.existing) {
        const isCurrent = await bcrypt.compare(config.passwordValue, person.existing.passwordHash);
        const currentHash = person.existing.passwordHash;
        Object.assign(person.existing, values, {
          passwordHash: isCurrent ? currentHash : passwordHash,
          sessionVersion: nextDemoSessionVersion(person.existing.sessionVersion, isCurrent),
        });
        await person.existing.save();
        person.user = person.existing;
        results.set(person.key, 'updated');
      } else {
        person.user = await models.User.create({ _id: stableId(`user:${person.key}`), ...values });
        results.set(person.key, 'created');
      }
    }
    const { records } = makeData(models, managed);
    const recordCounts = {};
    for (const { Model, id, values } of records) {
      const before = await Model.exists({ _id: id });
      const { _id: ignoredId, ...setValues } = values;
      await Model.findOneAndUpdate({ _id: id }, { $set: setValues }, { upsert: true, new: true, runValidators: true, setDefaultsOnInsert: true });
      const name = Model.modelName;
      recordCounts[name] ||= { created: 0, updated: 0 };
      recordCounts[name][before ? 'updated' : 'created']++;
    }
    const seededRecords = new Map();
    const brokenRelationships = [];
    for (const entry of records) {
      const value = await entry.Model.findById(entry.id).lean();
      if (!value) brokenRelationships.push(`${entry.key}: seeded record missing`);
      else seededRecords.set(entry.key, value);
    }
    const check = (condition, message) => { if (!condition) brokenRelationships.push(message); };
    const userIds = new Set(managed.map(person => String(person.user._id)));
    const chatParticipants = new Set((seededRecords.get('chat:direct')?.participants || []).map(String));
    for (const key of ['chat:direct:message:1', 'chat:direct:message:2', 'chat:group:message:1']) {
      const message = seededRecords.get(key), conversation = message && [...seededRecords.values()].find(item => item._id && String(item._id) === String(message.conversationId));
      check(Boolean(conversation && (conversation.participants || []).some(id => String(id) === String(message.senderId))), `${key}: sender must belong to its conversation`);
      if (message?.replyTo) check(records.some(item => String(item.id) === String(message.replyTo) && item.Model.modelName === 'Message'), `${key}: reply target must exist`);
    }
    check(chatParticipants.size === 2, 'direct chat must have exactly two members');
    for (const key of ['business:makena-market', 'business:jirani-studio']) {
      const organization = seededRecords.get(key);
      check(Boolean(organization && userIds.has(String(organization.ownerId))), `${key}: owner must be a seeded account`);
      for (const member of organization?.members || []) check(userIds.has(String(member.userId)), `${key}: member must be a seeded account`);
    }
    const businessIds = new Set(['business:makena-market', 'business:jirani-studio'].map(key => String(seededRecords.get(key)?._id)));
    const businessUsers = new Set(managed.filter(person => ['business-owner', 'business-staff'].includes(person.key)).map(person => String(person.user._id)));
    const catalogById = new Map([...seededRecords].filter(([key]) => key.startsWith('catalog:')).map(([, item]) => [String(item._id), item]));
    for (const [key, item] of seededRecords) {
      const modelName = records.find(entry => entry.key === key)?.Model.modelName;
      if (modelName?.startsWith('Business') && item.organizationId) check(businessIds.has(String(item.organizationId)), `${key}: organization must exist`);
      if (modelName === 'BusinessOrganization') {
        check(businessUsers.has(String(item.ownerId)), `${key}: owner must be a seeded business account`);
        for (const member of item.members || []) check(businessUsers.has(String(member.userId)), `${key}: member must be a seeded business account`);
      }
      if (modelName === 'BusinessDocument') {
        const linkedCustomer = item.customerId && [...seededRecords.values()].find(value => value._id && String(value._id) === String(item.customerId) && value.organizationId && String(value.organizationId) === String(item.organizationId));
        if (item.customerId) check(Boolean(linkedCustomer), `${key}: customer must exist in the same organization`);
        let subtotal = 0;
        for (const line of item.items || []) {
          const product = catalogById.get(String(line.catalogItemId));
          check(Boolean(product && String(product.organizationId) === String(item.organizationId)), `${key}: each catalogue item must exist in the same organization`);
          subtotal += Number(line.lineTotal || 0);
        }
        check(subtotal === Number(item.subtotal), `${key}: line totals must match subtotal`);
        check(Number(item.total) === Number(item.subtotal) + Number(item.tax || 0), `${key}: total must equal subtotal plus tax`);
      }
      if (modelName === 'BusinessTask') {
        if (item.assignedTo) check(businessUsers.has(String(item.assignedTo)), `${key}: assignee must be a seeded business account`);
        if (item.customerId) check([...seededRecords.values()].some(value => value._id && String(value._id) === String(item.customerId) && String(value.organizationId) === String(item.organizationId)), `${key}: customer must exist in the same organization`);
        if (item.documentId) check([...seededRecords.values()].some(value => value._id && String(value._id) === String(item.documentId) && String(value.organizationId) === String(item.organizationId)), `${key}: document must exist in the same organization`);
      }
      if (modelName === 'BusinessCase') {
        if (item.customerId) check([...seededRecords.values()].some(value => value._id && String(value._id) === String(item.customerId) && String(value.organizationId) === String(item.organizationId)), `${key}: customer must exist in the same organization`);
        for (const assignee of item.assignees || []) check(businessUsers.has(String(assignee)), `${key}: assignee must be a seeded business account`);
      }
      if (modelName === 'BusinessInboxAssignment') check([...seededRecords.values()].some(value => value._id && String(value._id) === String(item.conversationId) && Array.isArray(value.participants)), `${key}: assigned conversation must exist`);
      if (modelName === 'BusinessTradeRequest' && item.supplierId) check([...seededRecords.values()].some(value => value._id && String(value._id) === String(item.supplierId) && String(value.organizationId) === String(item.organizationId)), `${key}: supplier must exist in the same organization`);
    }
    const school = seededRecords.get('school:lakeview');
    for (const key of ['school:member:admin', 'school:member:teacher', 'school:member:parent']) {
      const member = seededRecords.get(key);
      check(Boolean(member && String(member.schoolId) === String(school?._id) && userIds.has(String(member.userId))), `${key}: school and account must exist`);
    }
    const schoolMemberIds = new Set(['school:member:admin', 'school:member:teacher', 'school:member:parent'].map(key => String(seededRecords.get(key)?.userId)));
    const schoolStudentNames = new Set([...seededRecords].filter(([key]) => key.startsWith('school:student:')).map(([, item]) => String(item.fullName).toLowerCase()));
    for (const [key, item] of seededRecords) {
      if (key.startsWith('school:student:')) check(String(item.schoolId) === String(school?._id), `${key}: school must exist`);
      if (key.startsWith('school:attendance:') || key.startsWith('school:assessment:')) {
        const student = [...seededRecords.entries()].find(([studentKey, value]) => studentKey.startsWith('school:student:') && String(value._id) === String(item.studentId))?.[1];
        const schoolMatches = Boolean(student && String(student.schoolId) === String(item.schoolId));
        const staffMatches = userIds.has(String(key.startsWith('school:attendance:') ? item.markedBy : item.recordedBy));
        check(Boolean(student && schoolMatches && staffMatches), `${key}: student=${Boolean(student)}, schoolMatch=${schoolMatches}, staffMatch=${staffMatches}`);
      }
      if (key.startsWith('school:announcement') || key.startsWith('school:staff-message') || key.startsWith('school:parent-message') || key.startsWith('school:parent-inbox') || key.startsWith('school:staff-inbox')) {
        check(String(item.schoolId) === String(school?._id) && schoolMemberIds.has(String(item.senderId)), `${key}: school and sender membership must exist`);
        if (item.recipientId) check(schoolMemberIds.has(String(item.recipientId)), `${key}: recipient membership must exist`);
      }
      if (key === 'school:conference') check(String(item.schoolId) === String(school?._id) && userIds.has(String(item.createdBy)), `${key}: school and creator must exist`);
      if (key.startsWith('school:fee:')) check(String(item.schoolId) === String(school?._id) && userIds.has(String(item.parentId)) && schoolStudentNames.has(String(item.studentName).toLowerCase()) && item.status === 'PENDING_VERIFICATION', `${key}: school, parent, student and simulated pending status must be valid`);
    }
    if (brokenRelationships.length) throw new Error(`Seed data integrity verification failed (${brokenRelationships.length} issue(s)): ${brokenRelationships.join('; ')}`);
    for (const person of managed) {
      const user = await models.User.findById(person.user._id).select('+passwordHash +demoSeedKey');
      if (!user || user.demoSeedKey !== DEMO_KEY || user.status !== 'active' || !(await bcrypt.compare(config.passwordValue, user.passwordHash))) throw new Error(`Demo account verification failed for ${person.email}`);
    }
    const loginResults = process.env.CHATIFY_SEED_VERIFY_LOGIN === 'YES' ? await verifyLoginApi(config.passwordValue) : new Map();
    const here = dirname(fileURLToPath(import.meta.url));
    await writeFile(resolve(here, '../DEMO_ACCOUNT_REGISTER.md'), renderRegister(managed, results, true, loginResults), 'utf8');
    console.log(JSON.stringify({ databaseName: config.databaseName, accounts: Object.fromEntries(results), recordCounts, dataIntegrity: { verifiedRecords: seededRecords.size, expectedRecords: records.length, brokenRelationships: 0 }, loginVerification: Object.fromEntries(loginResults), apiLoginVerified: loginResults.size === accounts.length && [...loginResults.values()].every(value => value === 'HTTP login passed'), simulatedPayments: true }, null, 2));
  } finally {
    await mongoose.disconnect();
  }
}

main().catch(error => {
  console.error(`Demo seed stopped: ${error?.message || 'unknown error'}`);
  process.exitCode = 1;
});
