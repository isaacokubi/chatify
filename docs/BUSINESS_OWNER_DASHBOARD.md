# Business Owner Dashboard

## Purpose

The Business tab now opens a dedicated Business Owner Dashboard. It provides a focused overview of the signed-in user's own business organizations and a route into the existing BusinessHub management experience.

## Owner eligibility

The dashboard calls the authenticated `GET /api/business/organizations` endpoint and displays only organizations whose server-returned `ownerId` matches the authenticated user ID.

The client-side comparison is not an authorization boundary. Every organization data request is independently authorized by the server's `requireOrg` membership check, and write/finance operations continue to apply manager, contributor and finance role checks.

Managers and staff who are members but are not the organization owner receive an explanatory state and can open the existing BusinessHub, where the backend remains authoritative for permitted operations.

## Workspace approval and billing gate\n\nBefore requesting organization dashboard metrics, the page calls the authenticated `GET /api/workspace-billing/business/:orgId` endpoint. A locked workspace does not fetch operational metrics. Pending platform approval is displayed without a checkout action. After approval, the owner can request the one-time setup fee or monthly Chatify workspace subscription through the existing checkout endpoint. If a payment is needed, the client starts the existing M-Pesa payment flow and refreshes access only after the payment API reports provider-confirmed success. A pending/unknown result remains pending; it is not treated as paid. These are Chatify subscription charges, not merchant sales or customer invoices.\n\n## Overview data

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


## Workspace billing and first-business onboarding

Before requesting operational metrics, the dashboard calls the owner-only `GET /api/workspace-billing/business/:orgId` endpoint. If billing is locked, it retains the business identity and displays the billing status without requesting protected business dashboard metrics.

- If platform approval is pending, the owner sees an approval-pending message and no checkout action.
- After approval, if the setup fee is unpaid, the owner can start the Chatify workspace setup checkout.
- If setup is paid but the subscription is expired/required, the owner can start the monthly workspace subscription checkout.
- The checkout creates/reuses the server payment record. The dashboard then requests M-Pesa initiation with the owner-entered phone number and polls the payment status.
- Access refresh occurs only after the server payment endpoint reports provider-confirmed `SUCCESS`. A pending initiation, phone prompt or client-side value does not unlock the workspace.
- A pending payment is not retried automatically as a new payment. The owner is told to refresh/reconcile before attempting another payment.

This is Chatify platform workspace billing. It is not the business's customer invoice, POS, order or merchant settlement flow. The zero-priced checkout widget test exercises the no-fee branch only; live M-Pesa provider acceptance remains unverified.


## Owner dashboard presentation

The owner landing page uses a responsive KPI layout with clear visual labels and operational context. It surfaces the server-provided owner briefing, a low-stock watchlist (up to five named items with current and reorder-level quantities), and shortcuts into sales/documents, customers, products/stock, and tasks/support cases. These shortcuts open the existing role-aware BusinessHub; they do not bypass its permissions.

The dashboard intentionally does not fabricate revenue, profit, conversion, or cash-flow figures. It only presents metrics returned by the organization-scoped dashboard API. A zero low-stock count is shown as a clear no-alert state, not as an inferred inventory health score.
