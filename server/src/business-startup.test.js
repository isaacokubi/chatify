// Regression test for the Business API boot sequence.
// The entrypoint must initialize auth and Socket.IO before registering Business routes.
// A temporal-dead-zone ReferenceError here prevents Render from starting the whole API.
import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test('API boots and Business endpoints return JSON auth errors', {timeout: 35000}, async (t) => {
  // Reserve an available local port, then release it for the child API process.
  const probe = createServer();
  await new Promise((resolve, reject) => {
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', resolve);
  });
  const address = probe.address();
  assert.ok(address && typeof address === 'object');
  const port = address.port;
  await new Promise((resolve, reject) => probe.close((error) => error ? reject(error) : resolve()));

  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: process.cwd(),
    env: {
      ...process.env,
      NODE_ENV: 'test',
      PORT: String(port),
      MONGODB_URI: '',
      JWT_SECRET: 'business-startup-regression-test-secret',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', (chunk) => { output += chunk.toString(); });
  child.stderr.on('data', (chunk) => { output += chunk.toString(); });

  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM');
      await Promise.race([
        new Promise((resolve) => child.once('exit', resolve)),
        wait(3000),
      ]);
    }
  });

  let response;
  let lastError;
  // Importing the complete API can take several seconds on a cold CI runner.
  // Keep polling inside the test timeout so startup checks are not flaky under load.
  for (let attempt = 0; attempt < 300; attempt += 1) {
    if (child.exitCode !== null) {
      assert.fail('API process exited before becoming ready. Startup output: ' + output);
    }
    try {
      response = await fetch(`http://127.0.0.1:${port}/api/business/organizations`, {
        signal: AbortSignal.timeout(1000),
      });
      break;
    } catch (error) {
      lastError = error;
      await wait(100);
    }
  }

  assert.ok(response, 'API did not start: ' + String(lastError) + '\n' + output);
  assert.equal(response.status, 401, 'Business route should be mounted and require authentication');
  assert.match(response.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await response.json(), {error: 'Authentication required'});

  // The Spark endpoint must exist on the API deployment. Without a token it should
  // return the normal auth error, not a misleading "endpoint not found" response.
  const sparksResponse = await fetch(`http://127.0.0.1:${port}/api/sparks`, {
    signal: AbortSignal.timeout(1000),
  });
  assert.equal(sparksResponse.status, 401);
  assert.match(sparksResponse.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await sparksResponse.json(), {error: 'Authentication required'});

  // The readiness endpoint must not report a disconnected database as healthy.
  const healthResponse = await fetch(`http://127.0.0.1:${port}/api/health`, {
    signal: AbortSignal.timeout(1000),
  });
  assert.equal(healthResponse.status, 503);
  const health = await healthResponse.json();
  assert.equal(health.ok, false);
  assert.equal(health.database, 'disconnected');

  // Enterprise routes must also mount after the shared auth middleware and fail closed.
  const enterpriseResponse = await fetch(`http://127.0.0.1:${port}/api/business/organizations/000000000000000000000000/enterprise/overview`, {
    signal: AbortSignal.timeout(1000),
  });
  assert.equal(enterpriseResponse.status, 401);
  assert.match(enterpriseResponse.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await enterpriseResponse.json(), {error: 'Authentication required'});
});
