import test from 'node:test';
import assert from 'node:assert/strict';
import {registerAdminBackupRoutes} from './admin-backups.js';

function setup() {
  const routes = new Map();
  const app = {
    get: (path, ...handlers) => routes.set('GET ' + path, handlers.at(-1)),
    post: (path, ...handlers) => routes.set('POST ' + path, handlers.at(-1)),
  };
  registerAdminBackupRoutes({app, auth: (_req, _res, next) => next(), requireAdmin: (_req, _res, next) => next()});
  function response() {
    return {
      statusCode: 200, body: null, ended: false,
      status(code) { this.statusCode = code; return this; },
      json(value) { this.body = value; return this; },
      end() { this.ended = true; return this; },
    };
  }
  return {routes, response};
}

test('backup inventory is read-only and reports missing recovery configuration', async () => {
  const old = {...process.env};
  delete process.env.CHATIFY_BACKUP_DIR;
  delete process.env.CHATIFY_RESTORE_TARGET_URI;
  delete process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION;
  delete process.env.MONGODB_URI;
  delete process.env.MONGO_URL;
  try {
    const {routes, response} = setup();
    const res = response();
    await routes.get('GET /api/admin/backups')({}, res);
    assert.equal(res.statusCode, 200);
    assert.deepEqual(res.body.backups, []);
    assert.equal(res.body.restoreConfigured, false);
    assert.equal(res.body.backupToolConfigured, false);
  } finally {
    for (const key of Object.keys(process.env)) if (!(key in old)) delete process.env[key];
    for (const [key, value] of Object.entries(old)) process.env[key] = value;
  }
});

test('restore rejects path traversal and malformed archive names', async () => {
  const {routes, response} = setup();
  const res = response();
  await routes.get('POST /api/admin/backups/:filename/restore')({params:{filename:'../production.archive.gz'}, body:{confirmRestore:true}}, res);
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /Invalid backup filename/);
});

test('restore remains disabled without an explicitly non-production target', async () => {
  const oldUri = process.env.CHATIFY_RESTORE_TARGET_URI;
  const oldFlag = process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION;
  delete process.env.CHATIFY_RESTORE_TARGET_URI;
  delete process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION;
  try {
    const {routes, response} = setup();
    const res = response();
    await routes.get('POST /api/admin/backups/:filename/restore')({params:{filename:'chatify-20261028T020000Z.archive.gz'}, body:{confirmRestore:true}}, res);
    assert.equal(res.statusCode, 503);
    assert.match(res.body.error, /Recovery is disabled/);
  } finally {
    if (oldUri === undefined) delete process.env.CHATIFY_RESTORE_TARGET_URI; else process.env.CHATIFY_RESTORE_TARGET_URI = oldUri;
    if (oldFlag === undefined) delete process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION; else process.env.CHATIFY_RESTORE_TARGET_IS_NON_PRODUCTION = oldFlag;
  }
});
