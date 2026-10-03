import test from 'node:test';
import assert from 'node:assert/strict';
import {corsOriginCallback,resolveClientOrigins,resolveNodeEnv} from '../src/config.js';

const isAllowed = (configuration, origin) => new Promise((resolve,reject) => {
  corsOriginCallback(configuration)(origin,(error,allowed) => error ? reject(error) : resolve(Boolean(allowed)));
});

test('runtime environment must be explicit and supported', () => {
  assert.equal(resolveNodeEnv('production'), 'production');
  assert.equal(resolveNodeEnv('development'), 'development');
  assert.equal(resolveNodeEnv('test'), 'test');
  assert.throws(() => resolveNodeEnv(undefined), /explicitly set/);
  assert.throws(() => resolveNodeEnv('staging'), /explicitly set/);
});

test('development can retain wildcard CORS for local Flutter web use', async () => {
  const config = resolveClientOrigins('*',false);
  assert.equal(await isAllowed(config,'http://localhost:5173'),true);
});

test('production denies wildcard origins and accepts only configured HTTPS origins', async () => {
  const wildcard = resolveClientOrigins('*',true);
  assert.equal(await isAllowed(wildcard,'https://untrusted.example'),false);
  const configured = resolveClientOrigins('https://chatify.example,https://admin.example',true);
  assert.equal(await isAllowed(configured,'https://chatify.example'),true);
  assert.equal(await isAllowed(configured,'https://untrusted.example'),false);
  assert.equal(await isAllowed(configured,undefined),true);
});

test('production CORS rejects non-HTTPS, paths and malformed origins', () => {
  assert.throws(()=>resolveClientOrigins('http://chatify.example',true),/HTTPS origins/);
  assert.throws(()=>resolveClientOrigins('https://chatify.example/app',true),/HTTPS origins/);
  assert.throws(()=>resolveClientOrigins('not-an-origin',true),/valid web origins/);
});
