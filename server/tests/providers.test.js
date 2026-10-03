import test from 'node:test';
import assert from 'node:assert/strict';
import {createEmailProvider,createStorageProvider,createNotificationProvider} from '../src/providers.js';

test('provider defaults stay local and never claim a production delivery', async () => {
  const email = await createEmailProvider({smtpUrl:'configured-but-not-wired'}).sendPasswordReset({token:'secret'});
  const notification = await createNotificationProvider({}).send({userId:'user'});
  const stored = await createStorageProvider({}).upload({path:'https://example.test/image.jpg'});
  assert.equal(email.sent, false);
  assert.equal(notification.mock, true);
  assert.equal(stored.mock, true);
  assert.equal(stored.url, 'https://example.test/image.jpg');
});

test('an injected email transport receives password reset payload', async () => {
  let delivered;
  const provider = createEmailProvider({}, {sendPasswordReset:async payload=>{delivered=payload;return {sent:true};}});
  assert.deepEqual(await provider.sendPasswordReset({email:'person@example.test'}), {sent:true});
  assert.equal(delivered.email, 'person@example.test');
});

test('configured FCM never reports delivery without a transport', async () => {
  await assert.rejects(
    createNotificationProvider({fcmProjectId:'configured'}).send({userId:'user'}),
    /adapter is not installed/,
  );
});
