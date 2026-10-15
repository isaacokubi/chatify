export function resolveNodeEnv(value) {
  const environment = typeof value === 'string' ? value.trim() : '';
  if (!['development', 'test', 'production'].includes(environment)) {
    throw new Error('NODE_ENV must be explicitly set to development, test, or production');
  }
  return environment;
}

export function requireProductionMongoUri(value) {
  const uri = typeof value === 'string' ? value.trim() : '';
  if (!uri) throw new Error('Production requires MONGODB_URI');
  return uri;
}

export function resolveClientOrigins(value, production = false) {
  const configured = typeof value === 'string' ? value.trim() : '';
  if (!production && (!configured || configured === '*')) {
    return {wildcard: true, origins: new Set()};
  }
  if (production && (!configured || configured === '*')) {
    return {wildcard: false, origins: new Set()};
  }
  const origins = new Set();
  for (const item of configured.split(',').map(origin => origin.trim()).filter(Boolean)) {
    let parsed;
    try {
      parsed = new URL(item);
    } catch {
      throw new Error('CLIENT_ORIGIN must contain valid web origins');
    }
    if (parsed.origin !== item || parsed.username || parsed.password ||
        parsed.pathname !== '/' || parsed.search || parsed.hash ||
        (production && parsed.protocol !== 'https:')) {
      throw new Error('CLIENT_ORIGIN must contain HTTPS origins in production');
    }
    origins.add(parsed.origin);
  }
  return {wildcard: false, origins};
}

export function corsOriginCallback(configuration) {
  return (origin, callback) => {
    // Allow browser-based local development against the deployed API without
    // requiring every temporary localhost port to be added to Render settings.
    // This exception only permits loopback HTTP origins; authentication and all
    // API authorization checks still run normally, and no remote HTTP origin is allowed.
    let isLocalDevelopmentOrigin = false;
    if (typeof origin === 'string') {
      try {
        const parsed = new URL(origin);
        isLocalDevelopmentOrigin =
          parsed.protocol === 'http:' &&
          (parsed.hostname === 'localhost' || parsed.hostname === '127.0.0.1' ||
            parsed.hostname === '[::1]') &&
          parsed.origin === origin;
      } catch {
        // Malformed Origin headers are not trusted.
      }
    }

    if (!origin || configuration.wildcard ||
        configuration.origins.has(origin) || isLocalDevelopmentOrigin) {
      callback(null, true);
    } else {
      callback(null, false);
    }
  };
}
