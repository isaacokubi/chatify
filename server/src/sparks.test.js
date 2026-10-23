import test from 'node:test';
import assert from 'node:assert/strict';
import {SPARK_LIFETIME_MS, sparkExpiry, isSparkActive, normalizeSparkText, normalizeSparkPayload, isAllowedSparkMediaUrl, markSparkViewed, sparkAudienceOwnerIds, canViewSpark} from './sparks.js';

test('sparks stay active for a full 24 hours regardless of views', () => {
  const createdAt = new Date('2026-10-23T00:00:00.000Z');
  const spark = {createdAt, expiresAt: sparkExpiry(createdAt), viewedBy: ['viewer-1']};
  assert.equal(spark.expiresAt.getTime() - createdAt.getTime(), SPARK_LIFETIME_MS);
  assert.equal(isSparkActive(spark, new Date(createdAt.getTime() + SPARK_LIFETIME_MS - 1)), true);
  assert.equal(isSparkActive(spark, spark.expiresAt), false);
});

test('spark text is trimmed and bounded', () => {
  assert.equal(normalizeSparkText('  hello  '), 'hello');
  assert.equal(normalizeSparkText(''), null);
  assert.equal(normalizeSparkText('x'.repeat(501)), null);
  assert.equal(normalizeSparkText(42), null);
});

test('Spark payloads support text, image and video stories with safe media URLs', () => {
  const pngBytes = Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]);
  const imageUrl = `data:image/png;base64,${pngBytes.toString('base64')}`;
  const mp4Bytes = Buffer.alloc(16);
  mp4Bytes.write('ftyp', 4, 'ascii');
  const videoUrl = `data:video/mp4;base64,${mp4Bytes.toString('base64')}`;

  assert.deepEqual(normalizeSparkPayload({type:'text',text:'  hello  '}), {type:'text',text:'hello'});
  assert.deepEqual(normalizeSparkPayload({type:'image',text:'A day out',mediaUrl:imageUrl}), {type:'image',text:'A day out',mediaUrl:imageUrl});
  assert.deepEqual(normalizeSparkPayload({type:'video',text:'A quick moment',mediaUrl:videoUrl}), {type:'video',text:'A quick moment',mediaUrl:videoUrl});
  assert.equal(normalizeSparkPayload({type:'video',mediaUrl:videoUrl}, true), null);
  assert.equal(normalizeSparkPayload({type:'image',mediaUrl:'data:image/png;base64,not-an-image'}), null);
  assert.equal(normalizeSparkPayload({type:'video',mediaUrl:imageUrl}), null);
  assert.equal(normalizeSparkPayload({type:'unsupported',text:'x'}), null);
  assert.equal(normalizeSparkPayload({type:'text',text:'x'.repeat(501)}), null);
  assert.equal(isAllowedSparkMediaUrl('https://res.cloudinary.com/demo/image/upload/v1/photo.jpg','image',true), true);
  assert.equal(isAllowedSparkMediaUrl('https://res.cloudinary.com/demo/video/upload/v1/clip.mp4','video',true), true);
  assert.equal(isAllowedSparkMediaUrl('https://example.test/clip.mp4','video',true), false);
});

test('Spark view is authorized to saved contacts and idempotently records the viewer', async () => {
  const updates = [];
  const spark = {authorId: 'owner-1'};
  const Spark = {
    findOne(filter) {
      assert.equal(filter._id, 'spark-id');
      assert.ok(filter.expiresAt.$gt instanceof Date);
      return {select: () => ({lean: async () => spark})};
    },
    updateOne: async (...args) => updates.push(args),
  };
  const SavedContact = {exists: async (filter) => filter.userId === 'owner-1' && filter.contactUserId === 'viewer-1'};
  const result = await markSparkViewed({
    sparkId: 'spark-id',
    viewerId: 'viewer-1',
    Spark,
    SavedContact,
    isValidObjectId: (value) => value === 'spark-id',
  });
  assert.deepEqual(result, {statusCode: 200, body: {ok: true, hasViewed: true}});
  assert.equal(updates.length, 1);
  assert.deepEqual(updates[0][1], {$addToSet: {viewedBy: 'viewer-1'}});
});

test('Spark audience uses the author-to-viewer contact relationship and deduplicates owners', async () => {
  const SavedContact = {
    find: (filter) => {
      assert.equal(filter.contactUserId, 'viewer-1');
      return {select: () => ({lean: async () => [
        {userId: 'author-1'}, {userId: 'author-1'}, {userId: 'author-2'},
      ]})};
    },
  };
  assert.deepEqual(await sparkAudienceOwnerIds({viewerId: 'viewer-1', SavedContact}),
    ['author-1', 'author-2']);
  assert.equal(await canViewSpark({
    spark: {authorId: 'author-1'}, viewerId: 'viewer-1',
    SavedContact: {exists: async (filter) => filter.userId === 'author-1' && filter.contactUserId === 'viewer-1'},
  }), true);
});

test('Spark authorization denies either blocked direction', async () => {
  const SavedContact = {exists: async () => true};
  assert.equal(await canViewSpark({
    spark: {authorId: 'author-1'}, viewerId: 'viewer-1', SavedContact,
    viewerBlockedIds: ['author-1'],
  }), false);
  assert.equal(await canViewSpark({
    spark: {authorId: 'author-1'}, viewerId: 'viewer-1', SavedContact,
    User: {exists: async (filter) => filter._id === 'author-1' && filter.blockedUsers === 'viewer-1'},
  }), false);
});

test('Spark owner does not record a view and unrelated users cannot view a contact Spark', async () => {
  const updates = [];
  const Spark = {
    findOne: () => ({select: () => ({lean: async () => ({authorId: 'owner-1'})})}),
    updateOne: async (...args) => updates.push(args),
  };
  const SavedContact = {exists: async () => false};
  const owner = await markSparkViewed({
    sparkId: 'spark-id', viewerId: 'owner-1', Spark, SavedContact,
    isValidObjectId: () => true,
  });
  const stranger = await markSparkViewed({
    sparkId: 'spark-id', viewerId: 'stranger', Spark, SavedContact,
    isValidObjectId: () => true,
  });
  assert.deepEqual(owner, {statusCode: 200, body: {ok: true, hasViewed: false}});
  assert.equal(stranger.statusCode, 404);
  assert.equal(updates.length, 0);
});

test('Spark view rejects malformed and expired identifiers without recording a view', async () => {
  let lookups = 0;
  const Spark = {
    findOne: () => {
      lookups++;
      return {select: () => ({lean: async () => null})};
    },
    updateOne: async () => assert.fail('expired Spark must not be updated'),
  };
  const SavedContact = {exists: async () => assert.fail('missing Spark has no contact lookup')};
  const invalid = await markSparkViewed({
    sparkId: 'bad', viewerId: 'viewer', Spark, SavedContact,
    isValidObjectId: () => false,
  });
  const expired = await markSparkViewed({
    sparkId: 'expired', viewerId: 'viewer', Spark, SavedContact,
    isValidObjectId: () => true,
  });
  assert.equal(invalid.statusCode, 400);
  assert.equal(expired.statusCode, 404);
  assert.equal(lookups, 1);
});
