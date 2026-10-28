#!/usr/bin/env node
/**
 * Read-only authenticated demo-account smoke test.
 *
 * Required environment:
 *   CHATIFY_API_URL=https://chatify-api-c1eh.onrender.com
 *   CHATIFY_DEMO_PASSWORD=<shared demo password>
 *
 * The password is read only from the environment, never printed, and is not stored.
 * This script makes no writes except the authentication service updating lastSeen on login.
 * It does not create chats, contacts, payments, school records, or initiate any M-Pesa request.
 */
const base = String(process.env.CHATIFY_API_URL || 'https://chatify-api-c1eh.onrender.com').replace(/\/+$/, '');
const password = process.env.CHATIFY_DEMO_PASSWORD;
if (!password) {
  console.error('FAIL: set CHATIFY_DEMO_PASSWORD in the private runtime environment (do not pass it as a command-line argument).');
  process.exit(2);
}
let parsedBase;
try {
  parsedBase = new URL(base);
  if (!['https:', 'http:'].includes(parsedBase.protocol)) throw new Error('unsupported protocol');
} catch {
  console.error('FAIL: CHATIFY_API_URL must be a valid HTTP(S) URL.');
  process.exit(2);
}
const accounts = [
  { email: 'admin@demo.chatify.test', label: 'platform administrator', admin: true },
  { email: 'alice@demo.chatify.test', label: 'chat demo user' },
  { email: 'brian@demo.chatify.test', label: 'chat demo user' },
  { email: 'nia@demo.chatify.test', label: 'business and store owner' },
  { email: 'sam@demo.chatify.test', label: 'business manager/owner' },
  { email: 'grace@demo.chatify.test', label: 'school administrator' },
  { email: 'peter@demo.chatify.test', label: 'school staff member' },
  { email: 'miriam@demo.chatify.test', label: 'school parent/guardian' },
];
const commonReads = [
  ['profile', '/api/auth/me'],
  ['contacts', '/api/contacts'],
  ['conversations', '/api/conversations'],
  ['payments list (read-only)', '/api/payments'],
  ['storefront catalogue index (read-only)', '/api/storefronts'],
  ['school workspaces (read-only)', '/api/schools'],
  ['business workspaces (read-only)', '/api/business/organizations'],
];
let passed = 0;
let failed = 0;
function report(ok, account, check, detail = '') {
  console.log(`${ok ? 'PASS' : 'FAIL'} | ${account} | ${check}${detail ? ' | ' + detail : ''}`);
  if (ok) passed++;
  else failed++;
}
async function request(path, { token, method = 'GET', body } = {}) {
  const response = await fetch(new URL(path, base), {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  let data = null;
  const text = await response.text();
  try { data = text ? JSON.parse(text) : null; } catch { /* status checks do not need body parsing */ }
  return { status: response.status, data };
}
for (const account of accounts) {
  let token;
  try {
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { email: account.email, password },
    });
    if (login.status !== 200 || typeof login.data?.token !== 'string' || !login.data?.user) {
      report(false, account.email, 'login', `HTTP ${login.status}; response body intentionally omitted`);
      continue;
    }
    token = login.data.token;
    report(true, account.email, 'login');
    const returnedEmail = String(login.data.user.email || '').toLowerCase();
    report(returnedEmail === account.email, account.email, 'identity matches requested account');
    const expectedRole = account.admin ? 'admin' : 'user';
    report(login.data.user.role === expectedRole, account.email, 'platform role', `expected ${expectedRole}, received ${String(login.data.user.role || 'missing')}`);

    for (const [name, path] of commonReads) {
      try {
        const result = await request(path, { token });
        report(result.status === 200, account.email, name, `HTTP ${result.status}`);
      } catch (error) {
        report(false, account.email, name, error?.name === 'TimeoutError' ? 'timeout' : 'request failed');
      }
    }
    try {
      const adminResult = await request('/api/admin/overview', { token });
      const expectedStatus = account.admin ? 200 : 403;
      report(adminResult.status === expectedStatus, account.email, 'server-side admin authorization', `expected HTTP ${expectedStatus}, received ${adminResult.status}`);
    } catch (error) {
      report(false, account.email, 'server-side admin authorization', error?.name === 'TimeoutError' ? 'timeout' : 'request failed');
    }
  } catch (error) {
    report(false, account.email, 'login/request', error?.name === 'TimeoutError' ? 'timeout' : 'network or TLS error');
  }
}
console.log(`\nDemo-account smoke summary: ${passed} passed, ${failed} failed; ${accounts.length} accounts attempted.`);
console.log('Scope: authenticated read-only API smoke only. This is not UI/browser, websocket, data-mutation, M-Pesa sandbox, or live-payment acceptance.');
process.exitCode = failed ? 1 : 0;
