# Verification record — 2026-10-22 (billing boundary)

## Scope

This change adds a regression test for the exact instant a workspace subscription's expiry plus configured grace period ends.

## Test added

- `workspace locks at the exact subscription-expiry-plus-grace boundary` in `server/src/workspace-billing-access.test.js`.
- Checks the workspace is accessible one millisecond before the grace-period boundary.
- Checks both the route-level billing gate and public marketplace billing helper lock access at the boundary itself.

## Expected verification commands

Run from the repository root:

```bash
cd server
npm test
npm run lint
```

The CI workflow must run these commands on the branch before this change is described as passing. This document intentionally does not claim that tests passed merely because the test was added.

## Acceptance / remaining checks

- [ ] GitHub Actions backend quality workflow passes on the commit containing this test.
- [ ] Full mobile/web CI remains green for the same branch commit.
- [ ] Validate live billing-provider callbacks and renewals in a safe sandbox; unit tests cannot prove production payment delivery.
- [ ] Verify the deployed API is running the intended commit before enabling billing enforcement for real tenants.

## Policy reminder

Chatify's transaction commission remains disabled. Workspace setup fees and recurring subscriptions are the intended monetization path. Never mark a workspace payment successful based only on STK initiation or a client-side claim.
