# Business Owner Dashboard

## Purpose

The Business tab now opens a dedicated Business Owner Dashboard. It provides a focused overview of the signed-in user's own business organizations and a route into the existing BusinessHub management experience.

## Owner eligibility

The dashboard calls the authenticated `GET /api/business/organizations` endpoint and displays only organizations whose server-returned `ownerId` matches the authenticated user ID.

The client-side comparison is not an authorization boundary. Every organization data request is independently authorized by the server's `requireOrg` membership check, and write/finance operations continue to apply manager, contributor and finance role checks.

Managers and staff who are members but are not the organization owner receive an explanatory state and can open the existing BusinessHub, where the backend remains authoritative for permitted operations.

## Overview data

For each selected owned organization, the dashboard calls:

`GET /api/business/organizations/:orgId/dashboard`

The server returns organization summary data and metrics scoped to that organization:

| Card | Server metric | Meaning |
|---|---|---|
| Customers | `customers` | Active, non-archived customers |
| Active products / services | `activeCatalogItems` | Active catalogue records |
| Business documents | `documents` | Up to 500 business documents returned by the dashboard aggregation |
| Open tasks | `openTasks` | Tasks not done or cancelled among up to 500 loaded task records |
| Open support cases | `openCases` | Cases not resolved or closed among up to 500 loaded case records |
| Branches | Organization `branches` array length | Configured branch records |
| Low-stock items | `lowStockItems` length | Up to 100 active catalogue items at/below configured low-stock threshold |

The dashboard does not infer sales revenue, profit, tax liability or reconciled payment totals from these counts. Where a server briefing is returned, it is displayed as text.

## Management workflows

The **Manage business workspace** action opens the existing BusinessHub. Existing workflows include catalogue, customers, sales documents, tasks, storefront publication, M-Pesa configuration, POS, and the additional business tools available in the current implementation.

Business invoices and orders must continue to use their supported merchant-scoped settlement flow. A platform-shortcode STK initiation or client-side success value is not proof that a merchant invoice/order has been paid.

## UX and failure handling

- Supports multiple owned organizations with an explicit selector.
- Refresh action and pull-to-refresh reload server metrics.
- Shows loading and API error states.
- Does not show organizations owned by another account.
- Gives members who are not owners a path to the existing role-aware BusinessHub.
- Uses a responsive metric grid.

## Verification

Automated widget coverage is added in `mobile/test/owner_dashboards_test.dart` for:
- An owner seeing their own organization metrics.
- A different owner's organization being excluded from the dashboard.

The GitHub Actions Flutter analysis/test/build result must be checked on the implementation PR before release. These widget tests do not replace database-backed cross-business API tests or payment-provider acceptance.

## Known boundaries

- Dashboard counts are not audited financial statements.
- Branch count is the number of configured branch records; it does not imply each branch has been staffed or operationally verified.
- Low-stock counts depend on configured stock and threshold fields.
- Payment, tax, POS, subscription and external provider acceptance remain separate release gates.
