export function createAuthMiddleware({verifyToken, findUser}) {
  return async function auth(req, res, next) {
    const header = req.headers.authorization || '';
    if (!header.startsWith('Bearer ')) return res.status(401).json({error:'Authentication required'});
    let payload;
    try { payload = verifyToken(header.slice(7)); }
    catch { return res.status(401).json({error:'Authentication required'}); }
    const user = await findUser(payload.sub);
    if (!user || user.status !== 'active') return res.status(401).json({error:'Authentication required'});
    // Revoke JWTs issued before password changes and resets.
    // Missing sv remains compatible with existing version-0 sessions.
    const tokenVersion = Number(payload.sv ?? 0);
    const currentVersion = Number(user.sessionVersion ?? 0);
    if (!Number.isSafeInteger(tokenVersion) || tokenVersion !== currentVersion) {
      return res.status(401).json({error:'Session expired. Please sign in again.'});
    }
    req.user = user;
    return next();
  };
}

// Platform administration is always checked against the authenticated server-side user.
export function createAdminMiddleware() {
  return function requireAdmin(req, res, next) {
    return req.user?.role === 'admin'
      ? next()
      : res.status(403).json({error:'Administrator access required'});
  };
}
