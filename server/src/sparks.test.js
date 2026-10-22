import test from 'node:test';
import assert from 'node:assert/strict';
import {SPARK_LIFETIME_MS, sparkExpiry, isSparkActive, normalizeSparkText, normalizeSparkPayload, isAllowedSparkMediaUrl} from './sparks.js';

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
