// Regression test for the API boot sequence and Business route registration.
// Importing the actual entrypoint catches initialization-order errors while
// avoiding an extra child process inside Node's isolated test worker.
import test from 'node:test';
import assert from 'node:assert/strict';

process.env.NODE_ENV = 'test';
process.env.PORT = '0';
process.env.MONGODB_URI = '';
process.env.JWT_SECRET = 'business-startup-regression-test-secret';
process.env.MPESA_ENV = 'mock';
process.env.MPESA_CALLBACK_TOKEN = 'platform-callback-test-token-0123456789abcdef';
process.env.SCHOOL_DARAJA_CALLBACK_TOKEN = 'school-callback-test-token-0123456789abcdef';

const {server, shutdown} = await import('./index.js');

test('API boots and Business endpoints return JSON auth errors', {timeout: 30000}, async t => {
  t.after(async () => {
    await shutdown();
    assert.equal(server.listening, false, 'API HTTP server should be closed after shutdown');
  });

  if (!server.listening) {
    await new Promise((resolve, reject) => {
      const onError = error => {
        server.off('listening', onListening);
        reject(error);
      };
      const onListening = () => {
        server.off('error', onError);
        resolve();
      };
      server.once('error', onError);
      server.once('listening', onListening);
    });
  }
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  const base = `http://127.0.0.1:${address.port}`;

  const request = path => fetch(`${base}${path}`, {signal: AbortSignal.timeout(5000)});
  const businessResponse = await request('/api/business/organizations');
  assert.equal(businessResponse.status, 401, 'Business route should be mounted and require authentication');
  assert.match(businessResponse.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await businessResponse.json(), {error: 'Authentication required'});

  // Spark must also be mounted and fail closed without authentication.
  const sparksResponse = await request('/api/sparks');
  assert.equal(sparksResponse.status, 401);
  assert.match(sparksResponse.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await sparksResponse.json(), {error: 'Authentication required'});

  // Readiness must not report a disconnected database as healthy.
  const healthResponse = await request('/api/health');
  assert.equal(healthResponse.status, 503);
  const health = await healthResponse.json();
  assert.equal(health.ok, false);
  assert.equal(health.database, 'disconnected');

  // Enterprise routes must mount after shared auth middleware and fail closed.
  const enterpriseResponse = await request('/api/business/organizations/000000000000000000000000/enterprise/overview');
  assert.equal(enterpriseResponse.status, 401);
  assert.match(enterpriseResponse.headers.get('content-type') || '', /application\/json/i);
  assert.deepEqual(await enterpriseResponse.json(), {error: 'Authentication required'});

  // Daraja callback request IDs and amounts are not source authentication.
  // Both routes must reject a caller that does not know the configured URL token
  // before touching transaction state or requiring a database connection.
  const forgedCallback = {
    Body: {stkCallback: {CheckoutRequestID: 'known-checkout', MerchantRequestID: 'known-merchant', ResultCode: 0}},
  };
  const paymentCallback = await fetch(`${base}/api/payments/daraja/callback/wrong-token`, {
    method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(forgedCallback),
  });
  assert.equal(paymentCallback.status, 404);
  assert.deepEqual(await paymentCallback.json(), {error: 'Not found'});
  const schoolCallback = await fetch(`${base}/api/schools/daraja/callback/wrong-token`, {
    method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(forgedCallback),
  });
  assert.equal(schoolCallback.status, 404);
  assert.deepEqual(await schoolCallback.json(), {error: 'Not found'});

  // Exercise the same idempotent graceful-shutdown path used for SIGTERM.
  await shutdown();
  assert.equal(server.listening, false);
});
