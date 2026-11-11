import test from 'node:test';
import assert from 'node:assert/strict';
import { resolveDemoSeedConfig } from './seedConfig.js';

const baseEnv = (overrides = {}) => ({
  NODE_ENV: 'development',
  CHATIFY_SEED_DEMO: 'YES',
  MONGODB_URI: 'mongodb://127.0.0.1:27017/chatify_demo',
  SEED_DEMO_PASSWORD: 'test-only-password-123',
  ...overrides,
});

test('demo seed requires development mode and explicit confirmation', () => {
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ NODE_ENV: 'production' })), /NODE_ENV=development/);
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ CHATIFY_SEED_DEMO: 'NO' })), /CHATIFY_SEED_DEMO=YES/);
});

test('demo seed requires an explicit MongoDB database name and rejects production names', () => {
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ MONGODB_URI: '' })), /MONGODB_URI is required/);
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ MONGODB_URI: 'mongodb://127.0.0.1:27017' })), /explicit database name/);
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ MONGODB_URI: 'mongodb://127.0.0.1:27017/chatify_production' })), /production-named database/);
});

test('unclassified database names require a second explicit acknowledgement', () => {
  const env = baseEnv({ MONGODB_URI: 'mongodb://127.0.0.1:27017/chatify' });
  assert.throws(() => resolveDemoSeedConfig(env), /CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE=YES/);
  assert.equal(resolveDemoSeedConfig({ ...env, CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE: 'YES' }).databaseName, 'chatify');
});

test('demo seed password must be 12–72 UTF-8 bytes', () => {
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ SEED_DEMO_PASSWORD: 'short' })), /12–72 UTF-8 bytes/);
  assert.throws(() => resolveDemoSeedConfig(baseEnv({ SEED_DEMO_PASSWORD: 'x'.repeat(73) })), /12–72 UTF-8 bytes/);
  assert.equal(resolveDemoSeedConfig(baseEnv({ SEED_DEMO_PASSWORD: 'x'.repeat(12) })).passwordValue, 'x'.repeat(12));
  assert.equal(resolveDemoSeedConfig(baseEnv({ SEED_DEMO_PASSWORD: 'x'.repeat(72) })).passwordValue, 'x'.repeat(72));
});

test('dry-run is explicit and returns the selected database without connecting', () => {
  const config = resolveDemoSeedConfig(baseEnv(), ['--dry-run']);
  assert.equal(config.dryRun, true);
  assert.equal(config.databaseName, 'chatify_demo');
  assert.equal(resolveDemoSeedConfig(baseEnv({ CHATIFY_SEED_DRY_RUN: 'YES' })).dryRun, true);
  assert.equal(resolveDemoSeedConfig(baseEnv()).dryRun, false);
});
