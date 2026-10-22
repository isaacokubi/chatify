import { resolveCallbackOutcome } from './payments.js';

// Process one Daraja callback through an injected atomic persistence boundary.
// Daraja does not provide a documented callback signature, so request references,
// amount, phone, receipt format, and a one-time database transition are all checked.
export async function processDarajaCallback({ callback, findPending, findExisting, transition }) {
  if (!callback || typeof callback.CheckoutRequestID !== 'string' ||
      !callback.CheckoutRequestID.trim() || callback.CheckoutRequestID.length > 200 ||
      typeof callback.MerchantRequestID !== 'string' ||
      !callback.MerchantRequestID.trim() || callback.MerchantRequestID.length > 200) {
    return { statusCode: 400, body: { error: 'Malformed callback' } };
  }

  const references = {
    checkoutRequestId: callback.CheckoutRequestID,
    merchantRequestId: callback.MerchantRequestID,
  };
  const payment = await findPending(references);
  if (!payment) {
    const existing = await findExisting(references);
    return {
      statusCode: 200,
      body: { ok: true, duplicate: true, ...(existing ? { payment: existing } : {}) },
    };
  }

  const outcome = resolveCallbackOutcome(callback, payment);
  if (outcome.error === 'malformed') {
    return { statusCode: 400, body: { error: 'Malformed callback' } };
  }
  if (outcome.error === 'mismatch') {
    return { statusCode: 400, body: { error: 'Callback details did not match the initiated payment' } };
  }

  // transition must atomically require PENDING + unprocessed callback and match both
  // provider references. A null result means another callback won the race.
  const updated = await transition({ payment, references, outcome });
  if (!updated) {
    const existing = await findExisting(references);
    return {
      statusCode: 200,
      body: { ok: true, duplicate: true, ...(existing ? { payment: existing } : {}) },
    };
  }

  return { statusCode: 200, body: { ok: true, duplicate: false, payment: updated } };
}
