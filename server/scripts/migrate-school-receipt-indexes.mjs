import mongoose from 'mongoose';

const uri = String(process.env.MONGODB_URI || '').trim();
const expectedDatabaseName = String(process.env.CHATIFY_EXPECTED_DATABASE_NAME || '').trim();
const confirmed = process.env.CHATIFY_CONFIRM_SCHOOL_RECEIPT_INDEX_MIGRATION === 'YES';

if (!uri || !expectedDatabaseName || !confirmed) {
  throw new Error('Set MONGODB_URI, CHATIFY_EXPECTED_DATABASE_NAME, and CHATIFY_CONFIRM_SCHOOL_RECEIPT_INDEX_MIGRATION=YES after independently verifying the target database.');
}

let parsed;
try {
  parsed = new URL(uri);
} catch {
  throw new Error('MONGODB_URI must be a valid MongoDB URI.');
}
if (!['mongodb:', 'mongodb+srv:'].includes(parsed.protocol)) {
  throw new Error('MONGODB_URI must use mongodb:// or mongodb+srv://.');
}
const actualDatabaseName = decodeURIComponent(parsed.pathname.replace(/^\\//, '').split('/')[0] || '');
if (!actualDatabaseName || actualDatabaseName !== expectedDatabaseName) {
  throw new Error('The database name in MONGODB_URI does not exactly match CHATIFY_EXPECTED_DATABASE_NAME.');
}

const migrations = [
  {
    collection: 'schoolfeepayments',
    obsolete: ['schoolId_1_mpesaReceipt_1', 'checkoutRequestId_1_merchantRequestId_1'],
    indexes: [
      {
        keys: { schoolId: 1, mpesaReceipt: 1 },
        options: {
          unique: true,
          name: 'school_fee_receipt_unique_nonempty_v1',
          partialFilterExpression: { mpesaReceipt: { $type: 'string' } },
        },
      },
      {
        keys: { checkoutRequestId: 1, merchantRequestId: 1 },
        options: {
          unique: true,
          name: 'school_fee_checkout_pair_unique_v1',
          partialFilterExpression: {
            checkoutRequestId: { $type: 'string' },
            merchantRequestId: { $type: 'string' },
          },
        },
      },
    ],
  },
  {
    collection: 'schooldonations',
    obsolete: ['schoolId_1_mpesaReceipt_1'],
    indexes: [
      {
        keys: { schoolId: 1, mpesaReceipt: 1 },
        options: {
          unique: true,
          name: 'school_donation_receipt_unique_nonempty_v1',
          partialFilterExpression: { mpesaReceipt: { $type: 'string' } },
        },
      },
    ],
  },
];

await mongoose.connect(uri, { autoIndex: false, serverSelectionTimeoutMS: 15000 });
try {
  const db = mongoose.connection.db;
  for (const migration of migrations) {
    const collectionExists = await db.listCollections({ name: migration.collection }, { nameOnly: true }).hasNext();
    if (!collectionExists) {
      console.log(`Skipping absent collection: ${migration.collection}`);
      continue;
    }
    const collection = db.collection(migration.collection);
    const current = await collection.listIndexes().toArray();
    for (const obsoleteName of migration.obsolete) {
      if (current.some(index => index.name === obsoleteName)) {
        await collection.dropIndex(obsoleteName);
        console.log(`Dropped obsolete index ${migration.collection}.${obsoleteName}`);
      }
    }
    for (const index of migration.indexes) {
      await collection.createIndex(index.keys, index.options);
      console.log(`Ensured index ${migration.collection}.${index.options.name}`);
    }
  }
  console.log(`School receipt index migration completed for database: ${actualDatabaseName}`);
} finally {
  await mongoose.disconnect();
}
