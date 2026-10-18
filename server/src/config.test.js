import test from 'node:test';
import assert from 'node:assert/strict';
import {corsOriginCallback, resolveClientOrigins} from './config.js';

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
