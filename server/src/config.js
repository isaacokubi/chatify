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
    if (!origin || configuration.wildcard || configuration.origins.has(origin)) {
      callback(null, true);
    } else {
      callback(null, false);
    }
  };
}
