import test from 'node:test';
import assert from 'node:assert/strict';
import {validateDisposableMongoTestUri} from './database-test-guard.js';

test('database integration guard accepts only named loopback audit databases', () => {
  assert.deepEqual(
    validateDisposableMongoTestUri('mongodb://127.0.0.1:27018/chatify_audit_test_20261026_flow'),
    {databaseName: 'chatify_audit_test_20261026_flow'},
  );
  assert.deepEqual(
    validateDisposableMongoTestUri('mongodb://127.0.0.1:27018/chatify_audit_test'),
    {databaseName: 'chatify_audit_test'},
  );
});

test('database integration guard refuses the application database and ambiguous names', () => {
  for (const database of ['chatify', 'chatify-test', 'chatify_audit_test_backup/other', '']) {
    assert.throws(
      () => validateDisposableMongoTestUri(`mongodb://127.0.0.1:27018/${database}`),
      /Disposable integration database name/,
      database || '(empty database)',
    );
  }
});

test('database integration guard refuses remote, credentialed or option-bearing URIs', () => {
  for (const [uri, expected] of [
    ['mongodb://mongo.example:27018/chatify_audit_test_remote', /127\.0\.0\.1:27018/],
    ['mongodb://127.0.0.1:27017/chatify_audit_test_wrong_port', /127\.0\.0\.1:27018/],
    ['mongodb://user:password@127.0.0.1:27018/chatify_audit_test_credentials', /must not contain credentials/],
    ['mongodb://127.0.0.1:27018/chatify_audit_test?authSource=admin', /must not contain options/],
    ['mongodb+srv://127.0.0.1/chatify_audit_test_srv', /direct MongoDB URI/],
  ]) {
    assert.throws(() => validateDisposableMongoTestUri(uri), expected);
  }
});

test('database integration guard rejects missing and malformed URIs', () => {
  assert.throws(() => validateDisposableMongoTestUri(''), /is required/);
  assert.throws(() => validateDisposableMongoTestUri('not a uri'), /valid MongoDB URI/);
});
