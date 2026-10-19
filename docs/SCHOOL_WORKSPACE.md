# Chatify School Workspace

This module adds school-scoped membership, parent/staff messaging, school announcements, parent conferences, configured payment destinations, fee records, and printable receipts.

## API

All endpoints except authentication are protected by the normal Chatify bearer-token middleware.

- `POST /api/schools` — create a school workspace; creator becomes its administrator.
- `GET /api/schools` — list the signed-in user's school workspaces.
- `POST /api/schools/:schoolId/members` — school administrator adds an existing Chatify account as staff or parent. Parent student names are attached to that membership.
- `GET /api/schools/:schoolId/members` — administrator/staff directory.
- `PUT /api/schools/:schoolId/payment-profile` — configure school Paybill, Till, or bank details.
- `POST/GET /api/schools/:schoolId/messages` — school-scoped direct messages and admin announcements.
- `POST/GET /api/schools/:schoolId/conferences` — create and view parent/staff conferences.
- `POST/GET /api/schools/:schoolId/fees` — parent records a fee payment attempt; school staff can list records.
- `POST /api/schools/:schoolId/fees/:paymentReference/verify` — administrator verifies a transaction with the actual M-Pesa receipt.
- `GET /api/schools/:schoolId/fees/:paymentReference/receipt` — downloadable, printable HTML receipt after verification.

## Important payment limitation

Configuring a Paybill/Till/bank destination does **not** itself enable automated STK Push or provider callback reconciliation. The current fee endpoint creates a clearly labelled pending record and returns the school's configured payment destination; it never claims money was collected. The school must verify the real transaction and receipt before a receipt can be downloaded. Automated merchant STK Push, signed/idempotent callback integration, and the parent-facing Flutter school screens are follow-up implementation gates before this feature should be described as complete or production-ready.

All school routes scope reads and writes by membership. Parents can only view their own fee records and receipts; staff cannot create school-wide announcements; only school administrators can manage membership, configure payment destinations, create conferences, and confirm fees.
