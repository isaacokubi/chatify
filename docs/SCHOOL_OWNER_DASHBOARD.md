# School Owner Dashboard

## Purpose

The School tab now opens a dedicated School Owner Dashboard. It is an owner-focused overview and entry point; the existing School Workspace remains the operational area for managing records.

## Owner eligibility

The dashboard calls the authenticated `GET /api/schools` endpoint and displays only school workspaces for which the server response contains both:

- `isOwner: true` (the authenticated user created the school workspace); and
- `role: "admin"` (the authenticated user has an active school administrator membership).

The Flutter filter is a presentation rule only. All record access remains protected by the server's school membership, role and linked-student checks. Staff and parents are not shown as school owners; they can still open the existing role-aware School Workspace.

## Overview data

For the selected owned school, the dashboard requests the first page with a one-record page size and uses the API's server-calculated `total` values:

| Card | Authenticated API | Meaning |
|---|---|---|
| Students | `GET /api/schools/:schoolId/students?page=1&limit=1` | Total students visible to this school admin |
| Attendance records | `GET /api/schools/:schoolId/attendance?page=1&limit=1` | Total attendance records in this school |
| School members | `GET /api/schools/:schoolId/members?page=1&limit=1` | Active school memberships |
| Fee balances | `GET /api/schools/:schoolId/fee-balances?page=1&limit=1` | Fee-balance records, not a monetary total |

The selected school name and code come from the authenticated school list. The dashboard does not fabricate figures or calculate money from client-side data.

## Workspace billing gate\n\nBefore requesting student, attendance, member or fee-balance totals, the dashboard calls the authenticated `GET /api/workspace-billing/school/:schoolId` endpoint. If the server reports `locked: true`, it suppresses protected overview requests and metric cards, shows the billing-required state and links to the existing School Workspace billing controls. The dashboard does not mark a fee as paid or unlock a school from a client-side action.\n\n## Management workflows

The **Manage school workspace** action opens the existing SchoolWorkspacePage, which continues to provide the implemented school modules, including messages, fee records, receipts, members, students, attendance, academics and owner/admin settings. Each module retains its existing API permission checks.

## UX and failure handling

- Supports multiple owned schools with an explicit workspace selector.
- Refresh action and pull-to-refresh reload the server data.
- Shows a loading indicator while requests are pending.
- Shows an API error state without replacing it with zero-valued success metrics.
- Shows a role-aware empty state for users who do not own a school, with a link to the existing School Workspace.
- Uses a responsive metric grid for phone, tablet and web widths.

## Verification

Automated widget coverage is added in `mobile/test/owner_dashboards_test.dart` for:
- An owner seeing their own school and server-returned metrics.
- A staff account not seeing a school as owner data.

The GitHub Actions Flutter analysis/test/build result must be checked on the implementation PR before release. These widget tests do not replace database-backed school isolation tests or real-device acceptance.

## Known boundaries

- Fee balances are a record count, not total fees due or collected.
- The dashboard is an overview, not a replacement for detailed school reporting.
- Student data must remain synthetic in demos and acceptance tests until the school privacy, guardian consent, retention and data-processing gates are approved.
- The app cannot claim first-school production readiness solely because this dashboard renders.


## Workspace billing gate

Before requesting school records, the owner dashboard calls the owner-only `GET /api/workspace-billing/school/:schoolId` endpoint. If the returned billing state is locked, the dashboard retains the school identity, displays the setup/subscription status and does not request student, attendance, membership or fee records. **Open school billing** navigates to the existing SchoolWorkspacePage, which contains the supported school workspace billing controls.

The dashboard does not unlock school records on checkout initiation. The existing billing flow must receive provider-confirmed payment before the server removes the access lock. School fee collection and school workspace subscription are separate payment flows.
