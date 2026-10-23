# School fee balance states

School fee calculations use whole-KSh safe integers to match the existing school payment contract. A balance is derived from an immutable issued student charge, authorized credits, and payment records whose status is exactly `CONFIRMED`. Pending STK requests, manual-verification requests, failed, cancelled, rejected, and reversed records do not reduce the outstanding amount.

The calculation helper accepts `configured: false` when no applicable issued charge exists. In that case it returns `status: "NOT_CONFIGURED"` and `balance: null`, rather than presenting a missing fee structure as a zero charge or a paid account. Callers should show an actionable configuration/issuance message and must not use this state as permission to collect a guessed amount.

For configured charges, the outstanding balance is `max(0, chargeAmount - credits - confirmedPaid)`; any excess confirmed payment is returned separately as `overpayment`. The helper does not silently mutate charge records or automatically refund excess amounts. Reversals and refunds must be reflected in the authoritative payment ledger before the balance is considered final.

Run the targeted tests with:

```sh
cd server
node --test src/school-fees.test.js
npm test
npm run lint
```

The targeted helper tests do not replace integration verification of the school API, MongoDB indexes, Flutter screens, or Safaricom callbacks. Do not claim those environments passed unless they were run.
