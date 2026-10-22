import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createEmailProvider,
  isAllowedMessageMediaUrl,
  createNotificationProvider,
  createStorageProvider,
  isSupportedImageData,
  isSupportedVideoData,
} from '../src/providers.js';

test('development providers mock without logging or returning reset tokens', async () => {
  const email = createEmailProvider({});
  const notification = createNotificationProvider({});
  const storage = createStorageProvider({});
  assert.deepEqual(await email.sendPasswordReset({email:'person@example.test',token:'private-token'}), {sent:false,mock:true});
  assert.deepEqual(await notification.send({token:'device-token'}), {mock:true});
  const image = await storage.upload({data:'iVBORw0KGgo=',mimeType:'image/png'});
  assert.equal(image.mock, true);
  assert.match(image.mediaUrl, /^data:image\/png;base64,/);
});

test('production email is unavailable without SMTP settings', async () => {
  const email = createEmailProvider({production:true});
  assert.equal(email.available, false);
  await assert.rejects(email.sendPasswordReset({}), /not configured/);
});

test('SMTP adapter sends a one-time reset token through an injected transport', async () => {
  let delivered;
  const email = createEmailProvider(
    {smtpUrl:'smtp://test.invalid',from:'Chatify <no-reply@example.test>'},
    {sendMail:async message => {delivered=message;return {messageId:'test-id'};}},
  );
  const result = await email.sendPasswordReset({
    email:'person@example.test',token:'test-reset-token',expiresAt:new Date('2026-10-03T12:00:00Z'),
  });
  assert.deepEqual(result, {sent:true});
  assert.equal(delivered.to, 'person@example.test');
  assert.match(delivered.text, /test-reset-token/);
  assert.equal(delivered.from, 'Chatify <no-reply@example.test>');
});

test('production media is unavailable without Cloudinary and never falls back to mock storage', async () => {
  const storage = createStorageProvider({production:true});
  assert.equal(storage.available, false);
  await assert.rejects(storage.upload({}), /Image storage is not configured/);
});

test('Cloudinary adapter validates image content and returns only a secure delivery URL', async () => {
  let uploaded;
  const storage = createStorageProvider({cloudinaryUrl:'configured-in-test'}, {
    upload:async (source, options) => {
      uploaded={source,options};
      return {secure_url:'https://res.cloudinary.com/demo/image/upload/chatify/test.png'};
    },
  });
  const result = await storage.upload({data:'iVBORw0KGgo=',mimeType:'image/png'});
  assert.deepEqual(result, {mediaUrl:'https://res.cloudinary.com/demo/image/upload/chatify/test.png'});
  assert.match(uploaded.source, /^data:image\/png;base64,/);
  assert.equal(uploaded.options.resource_type, 'image');
  assert.equal(uploaded.options.overwrite, false);
  await assert.rejects(storage.upload({data:'not-an-image',mimeType:'image/png'}), /valid JPEG/);
  await assert.rejects(createStorageProvider({cloudinaryUrl:'test'}, {
    upload:async()=>({secure_url:'http://insecure.example.test/image.png'}),
  }).upload({path:'https://source.example.test/image.png'}), /secure URL/);
});

test('image validation accepts images larger than 650 KB and rejects images above 10 MB', () => {
  // Build signature-valid PNG test data so this exercises the byte-size limit,
  // rather than accidentally failing only because the file signature is invalid.
  const pngSignature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const encodedPngOfSize = byteCount => {
    const bytes = Buffer.alloc(byteCount);
    pngSignature.copy(bytes);
    return bytes.toString('base64');
  };

  assert.equal(isSupportedImageData('iVBORw0KGgo=', 'image/png'), true);
  assert.equal(isSupportedImageData('iVBORw0KGgo=', 'image/jpeg'), false);
  assert.equal(isSupportedImageData('not-base64?', 'image/png'), false);
  assert.equal(isSupportedImageData(encodedPngOfSize(700 * 1024), 'image/png'), true);
  assert.equal(isSupportedImageData(encodedPngOfSize(10 * 1024 * 1024), 'image/png'), true);
  assert.equal(isSupportedImageData(encodedPngOfSize(10 * 1024 * 1024 + 1), 'image/png'), false);
});

test('video uploads validate MP4/WebM signatures and use Cloudinary video storage', async () => {
  const mp4Bytes = Buffer.alloc(16);
  mp4Bytes.write('ftyp', 4, 'ascii');
  const mp4 = mp4Bytes.toString('base64');
  const webmBytes = Buffer.from([0x1a, 0x45, 0xdf, 0xa3, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
  const webm = webmBytes.toString('base64');
  assert.equal(isSupportedVideoData(mp4, 'video/mp4'), true);
  assert.equal(isSupportedVideoData(webm, 'video/webm'), true);
  assert.equal(isSupportedVideoData(mp4, 'video/webm'), false);
  assert.equal(isSupportedVideoData('not-base64?', 'video/mp4'), false);

  let uploaded;
  const storage = createStorageProvider({cloudinaryUrl:'configured-in-test'}, {
    upload:async (source, options) => {
      uploaded={source,options};
      return {secure_url:'https://res.cloudinary.com/demo/video/upload/chatify/test.mp4'};
    },
  });
  const result = await storage.upload({data:mp4,mimeType:'video/mp4',mediaType:'video'});
  assert.equal(result.mediaUrl, 'https://res.cloudinary.com/demo/video/upload/chatify/test.mp4');
  assert.match(uploaded.source, /^data:video\/mp4;base64,/);
  assert.equal(uploaded.options.resource_type, 'video');
  assert.deepEqual(uploaded.options.allowed_formats, ['mp4', 'webm', 'mov']);
  await assert.rejects(storage.upload({data:'not-a-video',mimeType:'video/mp4',mediaType:'video'}), /valid MP4/);
});

test('production message records cannot contain mock data URLs', () => {
  assert.equal(isAllowedMessageMediaUrl('data:image/png;base64,iVBORw0KGgo=',false),true);
  assert.equal(isAllowedMessageMediaUrl('data:image/png;base64,iVBORw0KGgo=',true),false);
  assert.equal(isAllowedMessageMediaUrl('https://res.cloudinary.com/example/image.png',true),true);
  assert.equal(isAllowedMessageMediaUrl('https://untrusted.example/image.png',true),false);
});

test('FCM sends the existing generic message notification through an injected transport', async () => {
  let delivered;
  const fcm = createNotificationProvider({production:true}, {
    send:async message => {delivered=message;return 'fcm-message-id';},
  });
  assert.equal(await fcm.send({token:'test-device-token',messageId:'message-id',conversationId:'conversation-id',type:'message'}), 'fcm-message-id');
  assert.equal(delivered.token, 'test-device-token');
  assert.deepEqual(delivered.notification, {title:'Chatify',body:'You received a new message.'});
  assert.deepEqual(delivered.data, {type:'message',messageId:'message-id',conversationId:'conversation-id'});
});

test('production FCM refuses missing configuration instead of reporting mock success', async () => {
  const fcm = createNotificationProvider({production:true});
  assert.equal(fcm.available, false);
  await assert.rejects(fcm.send({token:'test-device-token'}), /not configured/);
});
