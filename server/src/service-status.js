// Public, secret-free service status summary for customers and operators.
// This endpoint reports observable process/database state only; it does not claim
// external providers are healthy unless Chatify can actually verify that dependency.
export function buildServiceStatus({databaseReady, uptimeSeconds = process.uptime(), now = new Date()}) {
  const database = databaseReady ? 'operational' : 'degraded';
  const overall = databaseReady ? 'operational' : 'degraded';
  return {
    service: 'Chatify API',
    status: overall,
    checkedAt: now.toISOString(),
    uptimeSeconds: Math.max(0, Math.floor(Number(uptimeSeconds) || 0)),
    components: [
      {name: 'HTTP API', status: 'operational'},
      {name: 'Database', status: database},
      {name: 'Real-time messaging', status: 'unverified', note: 'Socket transport is not independently probed by this public summary.'},
      {name: 'Payment providers', status: 'unverified', note: 'Payment availability depends on configured provider credentials and provider health.'},
    ],
    notice: 'Component status reflects Chatify observations, not a guarantee of third-party availability.',
  };
}

export function registerPublicStatusRoute({app, mongoose}) {
  app.get('/api/status', (_req, res) => {
    const ready = mongoose.connection.readyState === 1;
    const status = buildServiceStatus({databaseReady: ready});
    res.status(ready ? 200 : 503).set('Cache-Control', 'no-store').json(status);
  });
}


/**
 * Build the lightweight liveness/readiness response without exposing configuration.
 * HTTP 200 means the API process and its required database dependency are ready.
 */
export function buildHealthResponse({databaseReady, release = 'main'}) {
  const ready = databaseReady === true;
  return {
    statusCode: ready ? 200 : 503,
    body: {
      ok: ready,
      service: 'chatify-api',
      release: String(release || 'main').slice(0, 80),
      database: ready ? 'connected' : 'disconnected',
      features: {sparks: true},
    },
  };
}
