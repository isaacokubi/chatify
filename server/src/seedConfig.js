export function resolveDemoSeedConfig(env, argv = []) {
  if (env.NODE_ENV !== 'development') throw new Error('Demo seeding is allowed only when NODE_ENV=development');
  if (env.CHATIFY_SEED_DEMO !== 'YES') throw new Error('Set CHATIFY_SEED_DEMO=YES to confirm the designated demo seed');
  const rawUri = typeof env.MONGODB_URI === 'string' ? env.MONGODB_URI.trim() : '';
  if (!rawUri) throw new Error('MONGODB_URI is required; the target database must be explicitly configured');
  let databaseName;
  try {
    const parsed = new URL(rawUri);
    if (!['mongodb:', 'mongodb+srv:'].includes(parsed.protocol)) throw new Error();
    databaseName = decodeURIComponent(parsed.pathname.replace(/^\//, '').split('/')[0] || '');
  } catch {
    throw new Error('MONGODB_URI must be a valid MongoDB URI with an explicit database name');
  }
  if (!databaseName || /prod(?:uction)?/i.test(databaseName)) {
    throw new Error('Refusing to seed a production-named database');
  }
  if (!/(demo|dev(?:elopment)?|test)/i.test(databaseName) && env.CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE !== 'YES') {
    throw new Error('This database name is not clearly a demo/development/test target; set CHATIFY_SEED_ALLOW_UNCLASSIFIED_DATABASE=YES only after explicitly verifying the connected database');
  }
  const passwordValue = env.SEED_DEMO_PASSWORD ?? env.DEMO_SEED_PASSWORD;
  if (typeof passwordValue !== 'string' || Buffer.byteLength(passwordValue, 'utf8') < 12 || Buffer.byteLength(passwordValue, 'utf8') > 72) {
    throw new Error('SEED_DEMO_PASSWORD must be 12–72 UTF-8 bytes');
  }
  return { uri: rawUri, databaseName, passwordValue, dryRun: argv.includes('--dry-run') || env.CHATIFY_SEED_DRY_RUN === 'YES' };
}

export function nextDemoSessionVersion(currentVersion, passwordMatches) {
  const current = Number.isSafeInteger(Number(currentVersion)) && Number(currentVersion) >= 0 ? Number(currentVersion) : 0;
  return passwordMatches ? current : current + 1;
}
