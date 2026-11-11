# Chatify Onboarding Guide

This guide covers the existing authenticated onboarding paths for the platform, schools and businesses. Use a non-production test environment first. Do not create real student/customer records until privacy, security and provider gates have been approved.

## Platform administrator

- Provision the first platform administrator only with the documented server-side `npm run seed:admin` flow.
- Supply `MONGODB_URI`, `ADMIN_NAME`, `ADMIN_EMAIL` and `ADMIN_PASSWORD` privately.
- Use a unique password of 12–72 UTF-8 bytes.
- Confirm the account can reach the Control Center and a normal account receives HTTP 403 from platform-admin APIs.
- Never place credentials in Git, issue comments, logs or screenshots.

## School owner

The legacy direct `POST /api/schools` creation route is deliberately disabled. Production school creation requires the school verification request and platform review process.

1. Create or verify the owner's ordinary Chatify account.
2. Submit the school verification request through the app's school verification flow.
3. A platform-authorized reviewer approves or rejects the request with a recorded decision.
4. Approval creates the school workspace and its initial `admin` membership for the requester.
5. Sign in as the requester and confirm `GET /api/schools` returns the school with `isOwner: true` and `role: "admin"`.
6. Confirm the School tab opens the School Owner Dashboard and displays only this owner's school.
7. Use **Manage school workspace** to access the detailed School Workspace.
8. Add staff and parents only after verifying their accounts and the school's invitation process.
9. Link parents to the correct registered students and test that unrelated student IDs are denied.
10. Verify fee balances, receipts, attendance and academic records using synthetic data.

School join codes are for supported staff/parent membership only; they cannot grant administrator privileges. Staff invitations and parent/student linkage are documented in [School Workspace](SCHOOL_WORKSPACE.md).

## Business owner

1. Create or verify the owner's ordinary Chatify account.
2. Create a business workspace through the authenticated business organization flow.
3. Confirm the response's owner identity matches the signed-in account.
4. Confirm `GET /api/business/organizations` returns the organization only to its owner and current members.
5. Confirm the Business tab opens the Business Owner Dashboard for the owner.
6. Verify owner metrics are scoped to the selected organization.
7. Use **Manage business workspace** to access BusinessHub.
8. Configure organization profile, branches, catalogue and supported member roles.
9. Invite a manager/staff account and test the exact permissions assigned.
10. Test storefront visibility while unpublished and after explicit publication.
11. Keep live invoice/order settlement disabled until the merchant-scoped payment acceptance matrix is passed.

The business API sets `ownerId` from the authenticated user; clients cannot choose another owner. Business member roles and finance permissions are enforced by the server.

## Workspace and account switching

- Users with multiple memberships must select only a workspace returned by their authenticated membership list.
- Changing workspaces must not carry records, search filters or cached data from the previous tenant into the new workspace.
- Log out and sign back in when testing account changes; verify local protected state is cleared.
- Test revocation and membership removal with a previously issued session.

## Demo identities

The guarded development seed includes Lakeview Community School and Makena's Market. Demo identities are synthetic and must never be confused with real tenant owners. See [DEMO.md](DEMO.md).

## Acceptance evidence

Complete the two-tenant isolation matrix in [FIRST_TENANT_ACCEPTANCE.md](FIRST_TENANT_ACCEPTANCE.md). A successful dashboard render or seeded demo account is not proof of production onboarding. Keep payments and sensitive student-data workflows disabled until their separate release gates are signed off.


## Owner dashboard and billing behavior

The School tab is the school owner overview. It checks the owner-only workspace billing status first; a locked school owner is sent to the existing School Workspace billing controls before school records are requested.

The Business tab is the business owner overview. It checks platform approval and business workspace billing before requesting operational metrics. The owner can initiate Chatify setup/subscription M-Pesa checkout only after platform approval. The workspace becomes available only after server-side provider confirmation. This platform subscription is distinct from merchant payments made by customers to the business.
