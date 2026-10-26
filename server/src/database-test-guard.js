// Database integration tests drop their target before and after execution.
// Keep that destructive test harness confined to explicitly named disposable DBs.
export function validateDisposableMongoTestUri(value) {
  const raw = typeof value === 'string' ? value.trim() : '';
  if (!raw) throw new Error('CHATIFY_MONGO_TEST_URI is required');

  let uri;
  try {
    uri = new URL(raw);
  } catch {
    throw new Error('CHATIFY_MONGO_TEST_URI must be a valid MongoDB URI');
  }

  const databaseName = decodeURIComponent(uri.pathname.replace(/^\//, ''));
  if (uri.protocol !== 'mongodb:') {
    throw new Error('Disposable integration database must use a direct MongoDB URI');
  }
  if (uri.username || uri.password) {
    throw new Error('Disposable integration URI must not contain credentials');
  }
  if (uri.search || uri.hash) {
    throw new Error('Disposable integration URI must not contain options or fragments');
  }
  if (uri.hostname !== '127.0.0.1' || uri.port !== '27018') {
    throw new Error('Disposable integration database must use 127.0.0.1:27018');
  }
  if (!/^chatify_audit_test(?:_[a-zA-Z0-9-]+(?:_[a-zA-Z0-9-]+)*)?$/.test(databaseName)) {
    throw new Error('Disposable integration database name must start with chatify_audit_test');
  }

  return {databaseName};
}
