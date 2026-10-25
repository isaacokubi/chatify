// Serialize scheduled workflow ticks within this process and keep database outages quiet.
// MongoDB compare-and-set claims still provide cross-instance protection.
export function workflowErrorDetails(error) {
  const redact = value => String(value || '')
    .replace(/mongodb(?:\+srv)?:\/\/[^\s'"]+/gi, '[redacted MongoDB URI]')
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')
    .replace(/(password|token|secret|authorization)(\s*[:=]\s*)[^\s,;]+/gi, '$1$2[redacted]');
  const details = {
    name: redact(error?.name || 'Error').slice(0, 80),
    message: redact(error?.message || 'Unknown workflow scheduler error').slice(0, 500),
  };
  if (typeof error?.stack === 'string') {
    details.stack = redact(error.stack.split('\n').slice(0, 8).join('\n')).slice(0, 2000);
  }
  return details;
}

export function createWorkflowTickRunner({runTick, isDatabaseReady, logger = console}) {
  if (typeof runTick !== 'function') throw new TypeError('runTick must be a function');
  if (typeof isDatabaseReady !== 'function') throw new TypeError('isDatabaseReady must be a function');

  let running = false;
  return async function runWorkflowTickSafely() {
    if (running) return {skipped: 'already_running'};
    if (!isDatabaseReady()) return {skipped: 'database_unavailable'};

    running = true;
    try {
      await runTick();
      return {ok: true};
    } catch (error) {
      logger.error('Business workflow scheduler tick failed', workflowErrorDetails(error));
      throw error;
    } finally {
      running = false;
    }
  };
}
