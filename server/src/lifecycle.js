import {createHash, randomBytes} from 'node:crypto';

export const createResetToken = () => randomBytes(32).toString('hex');
export const hashResetToken = token => createHash('sha256').update(token).digest('hex');
export const resetExpiry = (now = Date.now()) => new Date(now + 30 * 60 * 1000);
export const validPassword = value => typeof value === 'string' && value.length >= 8 && Buffer.byteLength(value, 'utf8') <= 72;
export const messageExpiry = (mode, seconds, now = Date.now()) => {
  if (mode !== 'AFTER_TIME') return undefined;
  const boundedSeconds = Math.min(30 * 24 * 60 * 60, Math.max(60, Number(seconds) || 3600));
  return new Date(now + boundedSeconds * 1000);
};
export const expiresWhenRepliedTo = message => message?.expiryType === 'AFTER_REPLY';

export function createShutdownHandler({stopTimers,closeSockets,closeHttp,disconnectDb}) {
  let shutdown;
  return () => shutdown ||= (async()=>{
    stopTimers();
    await closeSockets();
    await closeHttp();
    await disconnectDb();
  })();
}

export function normalizeLoginCredentials(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  if (!email || email.length > 254 || !/^\S+@\S+\.\S+$/.test(email) ||
      !password || Buffer.byteLength(password, 'utf8') > 72) {
    return null;
  }
  return {email, password};
}
