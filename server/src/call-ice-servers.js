import {createHmac} from 'node:crypto';

const DEFAULT_STUN = 'stun:stun.l.google.com:19302';

export function buildCallIceServers({userId, turnUrls = '', sharedSecret = '', now = Date.now(), ttlSeconds = 3600}) {
  const iceServers = [{urls: DEFAULT_STUN}];
  const urls = String(turnUrls).split(',').map(value => value.trim()).filter(value => /^(turn|turns):/i.test(value));
  const secret = String(sharedSecret || '');
  if (!urls.length || secret.length < 32 || typeof userId !== 'string' || !userId) {
    return {iceServers, turnConfigured: false, expiresAt: null};
  }
  const ttl = Math.max(60, Math.min(3600, Number.isFinite(Number(ttlSeconds)) ? Number(ttlSeconds) : 3600));
  const expiresAtSeconds = Math.floor(now / 1000) + ttl;
  const username = expiresAtSeconds + ':' + userId;
  const credential = createHmac('sha1', secret).update(username).digest('base64');
  iceServers.push({urls, username, credential});
  return {iceServers, turnConfigured: true, expiresAt: new Date(expiresAtSeconds * 1000).toISOString()};
}
