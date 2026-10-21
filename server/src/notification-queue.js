export const MAX_NOTIFICATION_ATTEMPTS = 8;

// Exponential retry with a five-minute ceiling prevents a tight retry loop during outages.
export function notificationRetryDelayMs(attempts) {
  // Clamp exponent growth independently of the retry-count policy so the five-minute
  // ceiling is reachable and malformed/high attempt counts cannot overflow the exponent.
  const attempt = Math.max(1, Math.min(20, Number(attempts) || 1));
  return Math.min(5 * 60_000, 1_000 * (2 ** attempt));
}

// Retain completed/terminal queue metadata for 30 days for incident investigation.
export function notificationExpiryDate(now = new Date()) {
  return new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
}
