import test from 'node:test';
import assert from 'node:assert/strict';
import {corsOriginCallback, resolveClientOrigins, resolveMongoConnectionOptions} from './config.js';

test('MongoDB pool configuration is bounded and has safe timeout defaults', () => {
  assert.deepEqual(resolveMongoConnectionOptions({}), {
    maxPoolSize: 100,
    minPoolSize: 0,
    serverSelectionTimeoutMS: 8000,
    connectTimeoutMS: 10000,
    maxIdleTimeMS: 60000,
  });
  assert.equal(resolveMongoConnectionOptions({MONGODB_MAX_POOL_SIZE: '250'}).maxPoolSize, 250);
  for (const invalid of ['9', '501', '2.5', 'unlimited']) {
    assert.throws(() => resolveMongoConnectionOptions({MONGODB_MAX_POOL_SIZE: invalid}), /whole number from 10 to 500/);
  }
});

test('production CORS rejects a wildcard configuration instead of reflecting arbitrary origins', async () => {
  const config = resolveClientOrigins('*', true);
  const callback = corsOriginCallback(config);
  assert.equal(config.wildcard, false);
  assert.equal(config.origins.size, 0);
  await new Promise((resolve, reject) => {
    callback('https://attacker.example', (error, allowed) => {
      if (error) return reject(error);
      assert.equal(allowed, false);
      resolve();
    });
  });
});

test('production CORS allows only explicitly configured HTTPS origins', async () => {
  const callback = corsOriginCallback(resolveClientOrigins(
    'https://chatify-mobile.vercel.app,https://app.example.org',
    true,
  ));
  const check = origin => new Promise((resolve, reject) => {
    callback(origin, (error, allowed) => {
      if (error) return reject(error);
      resolve(allowed);
    });
  });
  assert.equal(await check('https://chatify-mobile.vercel.app'), true);
  assert.equal(await check('https://app.example.org'), true);
  assert.equal(await check('https://attacker.example'), false);
  assert.equal(await check('http://chatify-mobile.vercel.app'), false);
});

test('production CORS rejects HTTP and malformed configured origins', () => {
  assert.throws(() => resolveClientOrigins('http://chatify-mobile.vercel.app', true), /HTTPS origins in production/);
  assert.throws(() => resolveClientOrigins('not-a-url', true), /valid web origins/);
});

test('development can use a wildcard origin for local testing', async () => {
  const config = resolveClientOrigins('*', false);
  const callback = corsOriginCallback(config);
  assert.equal(config.wildcard, true);
  await new Promise((resolve, reject) => {
    callback('http://localhost:5173', (error, allowed) => {
      if (error) return reject(error);
      assert.equal(allowed, true);
      resolve();
    });
  });
});
