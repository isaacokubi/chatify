/**
 * School fee calculation primitives.
 *
 * School fee amounts are stored as whole KSh integers, matching the existing
 * school payment API. A fee structure is a reusable template; issuing it creates
 * immutable student-charge snapshots so later edits cannot rewrite old terms.
 */
export function normalizeFeeStructureInput(input = {}) {
  const className = typeof input.className === 'string' ? input.className.trim() : '';
  const academicYear = typeof input.academicYear === 'string' ? input.academicYear.trim() : '';
  const term = typeof input.term === 'string' ? input.term.trim() : '';
  if (!className || className.length > 80 || !academicYear || academicYear.length > 40 ||
      !term || term.length > 80 || !Array.isArray(input.items) ||
      input.items.length < 1 || input.items.length > 100) return null;

  const seen = new Set();
  const items = [];
  let totalAmount = 0;
  for (const raw of input.items) {
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
    const description = typeof raw.description === 'string' ? raw.description.trim() : '';
    const code = String(raw.code || description).trim().toUpperCase().replace(/\s+/g, '_').replace(/[^A-Z0-9_/-]/g, '_').replace(/_+/g, '_');
    const amount = raw.amount;
    if (!/^[A-Z0-9_/-]{1,32}$/.test(code) || !description || description.length > 120 ||
        !Number.isSafeInteger(amount) || amount <= 0 || amount > 100000000 || seen.has(code)) return null;
    seen.add(code);
    totalAmount += amount;
    if (!Number.isSafeInteger(totalAmount) || totalAmount > 1000000000) return null;
    items.push({code, description, amount});
  }
  return {className, academicYear, term, items, totalAmount};
}

/**
 * Derive a balance from the issued charge snapshot and confirmed payment records.
 * Pending/failed/cancelled/reversed records never reduce the amount owed.
 */
export function calculateSchoolFeeBalance({chargeAmount, payments = [], credits = 0}) {
  if (!Number.isSafeInteger(chargeAmount) || chargeAmount < 0 ||
      !Number.isSafeInteger(credits) || credits < 0 || !Array.isArray(payments)) {
    throw new TypeError('Fee charges, credits and payments must be non-negative whole-KSh amounts');
  }
  let confirmedPaid = 0;
  for (const payment of payments) {
    if (payment?.status !== 'CONFIRMED') continue;
    if (!Number.isSafeInteger(payment.amount) || payment.amount < 0) {
      throw new TypeError('Confirmed payment amounts must be non-negative whole-KSh amounts');
    }
    confirmedPaid += payment.amount;
    if (!Number.isSafeInteger(confirmedPaid)) throw new RangeError('Confirmed payment total is too large');
  }
  const netCharges = Math.max(0, chargeAmount - credits);
  const balance = Math.max(0, netCharges - confirmedPaid);
  const overpayment = Math.max(0, confirmedPaid - netCharges);
  return {
    chargeAmount,
    credits,
    confirmedPaid,
    balance,
    overpayment,
    status: balance === 0 ? 'PAID' : confirmedPaid > 0 ? 'PARTIALLY_PAID' : 'UNPAID',
  };
}
