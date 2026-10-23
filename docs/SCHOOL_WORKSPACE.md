# Chatify School Workspace

The school workspace supports learner admission, guardian contacts, attendance, academic records, parent/staff communication, conferences, fee collection and receipts. The Flutter workspace lays out learner, attendance, academic, fee and receipt records in horizontally scrollable tables so wide records remain readable on phone screens. Parent accounts only see learners linked to their school membership.

## Learners and records

Administrators and staff can register a pupil with an admission number, full name, class/grade and parent/guardian name, phone and email. They can edit these details or archive a pupil; archiving removes the learner from the active register while retaining historical fee, attendance and academic records. The learner table shows those fields in separate columns. Guardian contact details are used for school communication and receipt delivery; keep them current and restrict school membership appropriately.

Staff and administrators can record daily attendance (present, absent, late or excused) with an optional note, and academic results with subject, assessment, term/year, score, total marks and teacher comment. Parents can view records only for their linked learners. School IDs and membership are checked on the server for all reads and writes.

## Fees and receipts

Parents can select an enrolled learner, enter a term and amount, and use the payment method configured by the school. Supported paths include school-specific Daraja STK Push and manual M-Pesa Send Money or bank reconciliation. STK initiation remains pending until a callback validates the stored request IDs, amount, payer phone and M-Pesa receipt. Manual payment remains pending until an administrator verifies the actual receipt. A failed or pending payment never receives an official receipt.

After confirmation, the fee table and Receipts table provide a printable/downloadable PDF. The server retains the official HTML receipt. With SMTP configured, it sends the receipt to the paying parent and active school administrators; administrators can retry delivery. Only authorized school members can access a receipt, and parents are additionally checked against the payment's parent and linked pupil. Email delivery requires `SMTP_URL` and `SMTP_FROM`.

## API

All endpoints except provider callbacks require a Chatify bearer token and a school membership role.

- `POST /api/schools/:schoolId/students` — admin/staff register a learner.
- `GET /api/schools/:schoolId/students` — list active learners visible to the caller.
- `PATCH /api/schools/:schoolId/students/:studentId` — admin/staff update learner and guardian details.
- `DELETE /api/schools/:schoolId/students/:studentId` — admin/staff archive a learner, preserving history.
- `POST/GET /api/schools/:schoolId/attendance` — staff record attendance; parents read linked learners' records.
- `POST/GET /api/schools/:schoolId/academics` — staff record academic results; parents read linked learners' records.
- `POST/GET /api/schools/:schoolId/fees` — parents start or view fee payment records; school staff view school fees.
- `POST /api/schools/:schoolId/fees/:paymentReference/verify` — admin manually reconcile a payment using the actual receipt.
- `GET /api/schools/:schoolId/fees/:paymentReference/receipt` — authorized members download the confirmed official receipt.
- `POST /api/schools/:schoolId/fees/:paymentReference/receipt/resend` — admin retries receipt email.
- `POST /api/schools/daraja/callback` — provider callback, correlated and applied idempotently.

The API paginates school records. The current Flutter learner selector fetches up to 100 active learners; schools with more than 100 active learners need a searchable/paginated selector before the UI can address the full register efficiently. The table itself adapts to narrow viewports by horizontal scrolling. Automated checks cover school/business service behavior and a widget regression for the learner table's parent/guardian name, phone and email; a full school HTTP/browser/device E2E run has not been completed.

## Configuration and production limits

For automated Daraja fees configure `PUBLIC_API_URL`, `SCHOOL_PAYMENT_ENCRYPTION_KEY`, and each school's own approved credentials. Configure SMTP for automatic receipt emails. Keep real credentials out of source control and chat. A sandbox STK acceptance is initiation only, not successful payment. See [M-Pesa deployment notes](M-PESA-DEPLOYMENT.md), the [QA report](QA_REPORT_2026-10-23.md) and [database notes](DATABASE.md).


## Class fee structures and balances

Administrators can create versioned fee structures for a specific class/grade, academic year and term through the authenticated `/api/schools/:schoolId/fee-structures` API. Each item is a positive whole-KSh amount; the server validates item codes, prevents duplicate items, and computes the total instead of trusting a client-supplied total. Only school administrators can create a structure or issue charges. Staff can read structures; parent balance queries are restricted to the students linked to their school membership.

A fee structure is a template, not itself a student debt. An administrator explicitly issues an active structure to currently enrolled students with `POST /api/schools/:schoolId/fee-structures/:structureId/issue`. The server creates an immutable `SchoolStudentCharge` snapshot containing the student, class, period, items, total, structure version and issuer. A unique school/student/year/term index and `$setOnInsert` make repeated issuance idempotent. Editing a template archives the previous version and creates a new version; existing issued charges are never overwritten. Students who already have a charge for that period keep the original amount, so adjustments to already-issued charges must be recorded explicitly rather than silently applied.

`GET /api/schools/:schoolId/fee-balances` calculates each balance from the immutable charge snapshot, charge credits, and linked `SchoolFeePayment` records in `CONFIRMED` state only. Pending STK requests, pending manual verification, failed, cancelled, rejected and reversed-like statuses do not reduce the balance. The response includes charged amount, confirmed amount paid, outstanding balance, overpayment and payment status. New school fee requests are linked to the registered student and issued charge. Where a school has begun configuring fee structures, the API requires a matching active structure and issued charge before accepting a payment request, and rejects amounts above the current outstanding balance.

Amounts use whole-KSh safe integers to remain consistent with the existing payment contract. Historical payment records created before this feature may not contain a stable student ID/academic year and are not silently matched by display name; reconcile those legacy records before relying on a new issued-charge balance as a complete historical ledger. A deployment should run the backend tests and create the schema indexes through the repository's normal MongoDB index initialization before enabling fee structures for a school. The app does not claim automatic M-Pesa reversal discovery; an actual reversal must be reconciled through the existing payment operations before the balance can be considered final.


Confirmed school payments can be marked `REVERSED` by a school administrator only after the actual reversal is verified. The `POST /api/schools/:schoolId/fees/:paymentReference/reverse` route requires a reversal reference and reason, performs an atomic state transition, and is idempotent for the same reference. A school-scoped unique index prevents one reversal reference from being applied to multiple payments. Original payment and receipt metadata are retained for audit; a reversed payment no longer reduces the balance. This is manual reconciliation, not automatic Safaricom reversal discovery.
