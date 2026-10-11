// AUTHENTICATION HELPER
// Builds Express middleware that extracts a Bearer token, verifies its signature/expiry,
// loads the corresponding user, and rejects missing or invalid sessions before route logic runs.

export function createAuthMiddleware({verifyToken, findUser}) {
  return async function auth(req, res, next) {
    const header = req.headers.authorization || '';
    if (!header.startsWith('Bearer ')) return res.status(401).json({error:'Authentication required'});
    let payload;
    try { payload = verifyToken(header.slice(7)); }
    catch { return res.status(401).json({error:'Authentication required'}); }
    const user = await findUser(payload.sub);
    if (!user || user.status !== 'active') return res.status(401).json({error:'Authentication required'});
    req.user = user;
    return next();
  };
}
