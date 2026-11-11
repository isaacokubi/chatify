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
  { email: 'nia@demo.chatify.test', label: 'business and store owner', businessMember: true },
  { email: 'sam@demo.chatify.test', label: 'business manager', businessMember: true },
  { email: 'grace@demo.chatify.test', label: 'school administrator', schoolRole: 'admin' },
  { email: 'peter@demo.chatify.test', label: 'school staff member', schoolRole: 'staff' },
  { email: 'miriam@demo.chatify.test', label: 'school parent/guardian', schoolRole: 'parent' },
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
  return { status: response.status, data, headers: response.headers };
}
async function loginWithRateLimitRetry(account) {
  // The API intentionally rate-limits authentication. Respect Retry-After /
  // RateLimit-Reset and never bypass or parallelize the login limiter.
  for (let retry = 0; retry <= 2; retry += 1) {
    const result = await request('/api/auth/login', {
      method: 'POST',
      body: { email: account.email, password },
    });
    if (result.status !== 429) return result;
    if (retry === 2) throw new Error(`Login rate limit remained active after two full-window waits for ${account.email}.`);
    const resetSeconds = Number(result.headers?.get('retry-after') || result.headers?.get('ratelimit-reset'));
    const waitMs = Number.isFinite(resetSeconds) && resetSeconds > 0
      ? Math.ceil(resetSeconds * 1000) + 1000
      : 15 * 60 * 1000 + 1000;
    console.warn(`Login rate limit reached for ${account.email}; waiting ${waitMs}ms before a safe retry.`);
    await new Promise(resolve => setTimeout(resolve, waitMs));
  }
  throw new Error('Unreachable login retry state.');
}
for (const account of accounts) {
  let token;
  try {
    const login = await loginWithRateLimitRetry(account);
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

    // The canonical demo fixture is exactly one business plus one school.
    // Verify that only enrolled accounts can see each workspace and its records.
    try {
      const businessResult = await request('/api/business/organizations', { token });
      const organizations = Array.isArray(businessResult.data?.organizations) ? businessResult.data.organizations : [];
      const expectedBusinessCount = account.businessMember ? 1 : 0;
      report(businessResult.status === 200 && organizations.length === expectedBusinessCount,
        account.email, 'business membership scope',
        `expected ${expectedBusinessCount} workspace(s), received ${organizations.length}`);
      if (account.businessMember && (organizations[0]?._id || organizations[0]?.id)) {
        const organizationId = organizations[0]._id || organizations[0].id;
        const details = await request(`/api/business/organizations/${encodeURIComponent(organizationId)}`, { token });
        report(details.status === 200, account.email, 'authorized business workspace detail', `HTTP ${details.status}`);
        const catalogue = await request(`/api/business/organizations/${encodeURIComponent(organizationId)}/catalog`, { token });
        report(catalogue.status === 200 && Array.isArray(catalogue.data?.items) && catalogue.data.items.length === 7,
          account.email, 'business catalogue records', `HTTP ${catalogue.status}; expected 7 items`);
      }
    } catch (error) {
      report(false, account.email, 'business membership/records', error?.name === 'TimeoutError' ? 'timeout' : 'request failed');
    }

    try {
      const schoolResult = await request('/api/schools', { token });
      const schools = Array.isArray(schoolResult.data?.schools) ? schoolResult.data.schools : [];
      const expectedSchoolCount = account.schoolRole ? 1 : 0;
      report(schoolResult.status === 200 && schools.length === expectedSchoolCount,
        account.email, 'school membership scope',
        `expected ${expectedSchoolCount} workspace(s), received ${schools.length}`);
      if (account.schoolRole && schools[0]) {
        const school = schools[0];
        report(school.role === account.schoolRole, account.email, 'school membership role',
          `expected ${account.schoolRole}, received ${String(school.role || 'missing')}`);
        const students = await request(`/api/schools/${encodeURIComponent(school.id)}/students?limit=100`, { token });
        report(students.status === 200 && students.data?.total === 6 && Array.isArray(students.data?.students) && students.data.students.length === 6,
          account.email, 'school student visibility', `HTTP ${students.status}; expected 6 linked students`);
      }
    } catch (error) {
      report(false, account.email, 'school membership/records', error?.name === 'TimeoutError' ? 'timeout' : 'request failed');
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
console.log('Scope: authenticated read-only API smoke, including one-business/one-school membership and seeded record visibility. This is not approval workflow, UI/browser, websocket, data-mutation, M-Pesa sandbox, or live-payment acceptance.');
process.exitCode = failed ? 1 : 0;
