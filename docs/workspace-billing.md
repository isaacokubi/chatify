# Chatify workspace billing

Chatify no longer adds a percentage commission to personal transfers, business checkout, POS sales, invoices, or school-fee payments. Merchants and schools receive payments through their configured M-Pesa flow; Safaricom/provider charges may still apply.

## Pricing

Prices are configurable by a Chatify administrator through:
- `GET /api/admin/workspace-billing-settings`
- `PUT /api/admin/workspace-billing-settings`

Initial defaults (KES):
- Business workspace setup: 1,000 once
- Business workspace subscription: 500 per month
- School workspace setup: 5,000 once
- School workspace subscription: 2,500 per month
- Grace period after subscription expiry: 3 days

These are launch defaults, not fixed prices. Set production prices before onboarding paying customers.

## Workspace owner payment flow

1. Create a business workspace or submit a school verification request.
2. After school approval, the school owner can pay its one-time setup fee.
3. Once setup is confirmed, the owner purchases the monthly subscription.
4. The billing API returns a pending payment ID. The client calls `POST /api/payments/:paymentId/initiate` with the Kenyan phone number that should receive the STK prompt.
5. A workspace is activated/unlocked only after a validated successful M-Pesa callback updates the payment and billing entitlement.
6. The owner can check status/prices at `GET /api/workspace-billing/:type/:workspaceId`, where `type` is `business` or `school`.

Create a billing checkout:
```http
POST /api/workspace-billing/business/<workspaceId>/checkout
Authorization: Bearer <owner-token>
Content-Type: application/json

{"billingType":"workspace_setup"}
```

Use `workspace_subscription` for the monthly renewal. Subscription renewal is available only after the setup fee is paid.

## Locking and existing workspaces

New workspaces have billing enforcement enabled. Business API operations, POS access, public storefront checkout, and school member operations are blocked with HTTP 402 and `WORKSPACE_BILLING_REQUIRED` if setup is unpaid or the monthly subscription is expired beyond the configured grace period. Billing status and checkout endpoints remain accessible to the workspace owner.

Existing workspaces with no `billing.billingEnforced` flag are grandfathered and remain available; this avoids unexpectedly locking existing tenants. An administrator should communicate new terms and deliberately migrate existing workspaces before enabling enforcement for them.

## Security and payment safety

- Only the workspace owner can start setup/subscription checkout.
- The client cannot choose the amount; the server reads the administrator-configured price.
- Payment IDs are unique and successful callback application is idempotent, preventing duplicate callbacks from extending a subscription repeatedly.
- A sent STK prompt is not proof of payment.
- Never manually mark a payment successful based on client input. Only the validated payment callback updates billing entitlements.
- Payment initiation uses the existing Chatify Daraja provider configuration. Configure and test the production shortcode, passkey, credentials, callback URL, and wallet before accepting live workspace payments.
- The setup fee is one-time; monthly subscription payments extend the expiry from the later of the current expiry or payment time.

## Admin API example

```http
PUT /api/admin/workspace-billing-settings
Authorization: Bearer <admin-token>
Content-Type: application/json

{
  "businessSetupFee": 1000,
  "businessMonthlyFee": 500,
  "schoolSetupFee": 5000,
  "schoolMonthlyFee": 2500,
  "gracePeriodDays": 3
}
```

This backend implementation exposes billing APIs. A client UI should present the owner with setup/subscription status, amount due, the phone number for the STK prompt, and a retry path for failed/cancelled payments.
