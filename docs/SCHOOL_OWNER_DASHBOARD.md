# School Owner Dashboard

## Purpose

The School tab opens a dedicated owner overview. The existing SchoolWorkspacePage remains the detailed workspace for managing school records and operations.

## Owner eligibility and data

The dashboard calls the authenticated `GET /api/schools` endpoint and displays only schools for which the server response reports both `isOwner: true` and `role: "admin"`. This client-side filter is presentation only; backend membership, role and linked-student authorization remain authoritative.

For an unlocked selected school, the dashboard requests server-calculated totals:

| Card | Authenticated API | Meaning |
|---|---|---|
| Students | `GET /api/schools/:schoolId/students?page=1&limit=1` | Total students visible to the school admin |
| Attendance records | `GET /api/schools/:schoolId/attendance?page=1&limit=1` | Attendance record count |
| School members | `GET /api/schools/:schoolId/members?page=1&limit=1` | Membership count |
| Fee balances | `GET /api/schools/:schoolId/fee-balances?page=1&limit=1` | Fee-balance record count, not a monetary total |

## Workspace approval and billing

Before requesting those protected school metrics, the dashboard calls the owner-authenticated `GET /api/workspace-billing/school/:schoolId` endpoint. If the response reports `locked: true`, it does not request student, attendance, member or fee-balance records.

The owner can pay the Chatify workspace setup fee or monthly workspace subscription directly from the dashboard. The client calls `POST /api/workspace-billing/school/:schoolId/checkout`; if a payment is due, it initiates the returned payment through the existing `POST /api/payments/:paymentId/initiate` endpoint and polls the authenticated payment status. The dashboard refreshes access only after the payment API reports `SUCCESS`. A checkout request or pending M-Pesa prompt does not unlock school records.

This Chatify workspace charge is separate from school fee collection, receipts and donations. Those school financial workflows are not altered by this dashboard.

## Management workflows and UX

- **Manage school workspace** opens the existing SchoolWorkspacePage for detailed messages, fee records, receipts, members, students, attendance, academics and owner/admin settings.
- Multiple owned schools can be selected with the workspace selector.
- Refresh and pull-to-refresh reload server data.
- Loading and API error states are shown explicitly; an API failure is not presented as a successful zero count.
- Staff and parents are not presented as owners and can continue to the existing role-aware School Workspace.
- The metric grid adapts to phone, tablet and web widths.

## Verification and boundaries

Widget tests in `mobile/test/owner_dashboards_test.dart` cover owner metrics, staff exclusion, multi-school switching, billing lock behavior and the zero-priced setup checkout path. These tests do not replace database-backed cross-school integration tests, real M-Pesa acceptance or physical-device testing.

Fee balances are a record count, not total fees due or collected. Keep student data synthetic until school privacy, guardian consent, retention and data-processing requirements have been approved. The dashboard rendering alone is not evidence of first-school production readiness.


## Owner dashboard presentation

The school owner landing page presents the existing server-calculated totals in responsive metric cards with clear visual labels. It adds an operational section for students/admissions, attendance, fees/balances, and staff/school members, plus a distinct data-protection section. Each shortcut opens the existing SchoolWorkspacePage, where the authenticated school APIs and role checks continue to govern the actual operations.

The fee-balance KPI remains a record count and is not presented as a currency total. No academic performance, attendance percentage, fee collection rate, or other derived statistic is invented by the overview.
