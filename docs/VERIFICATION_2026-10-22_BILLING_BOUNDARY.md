# Verification record — 2026-10-22 (billing boundary)

## Scope

This change adds a regression test for the exact instant a workspace subscription's expiry plus configured grace period ends.

## Test added

- `workspace locks at the exact subscription-expiry-plus-grace boundary` in `server/src/workspace-billing-access.test.js`.
- Checks the workspace is accessible one millisecond before the grace-period boundary.
- Checks both the route-level billing gate and public marketplace billing helper lock access at the boundary itself.
- Added a second regression test to ensure monthly renewal from January 31 resolves to February 28 instead of overflowing into March.

## Verified CI evidence

The full **Chatify CI** workflow completed successfully for the billing-boundary branch commit `b0ee679832d825bd2949f7767547715688b84005` (merged as `3102dc9a437b1555a9070645cba02af47efbcbfe`). A follow-up month-end renewal regression test was added on `main` in commit `dfe0ec01676fe835279ceda9dec0b81d9517890b`.

- [Full CI run for billing-boundary change — success](https://github.com/isaacokubi/chatify/actions/runs/39735038381)
- [Follow-up quality checks including month-end test](https://github.com/isaacokubi/chatify/actions/runs/39736274225) — **passed** for both backend tests/syntax checks and Flutter analysis/tests on commit `dfe0ec01676fe835279ceda9dec0b81d9517890b`.
- [Follow-up full CI](https://github.com/isaacokubi/chatify/actions/runs/39736274262) — pending at the last check.
- Backend: `npm ci`, dependency audit, `npm test`, `npm run lint`, backup/recovery script validation, and production-URI restore guard passed.
- Mobile: Flutter dependency resolution, analysis, tests, web build, and Android debug APK build passed.
- The successful branch CI verifies the merged source contents; post-merge workflows on `main` are tracked separately below and must finish before the latest main-run status is declared final.

## Reproduction commands

Run from the repository root:

```bash
cd server
npm ci
npm test
npm run lint
cd ../mobile
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter build web --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com
```

For the Android debug APK, use the repository's committed Gradle configuration and the same Android SDK setup as the CI workflow.

## Acceptance / remaining checks

- [x] Full Chatify CI passed for the source commit containing the billing-boundary regression test.
- [x] Backend tests and syntax checks passed for the follow-up month-end renewal regression test in commit `dfe0ec01676fe835279ceda9dec0b81d9517890b`.
- [x] Follow-up quality checks passed for the month-end test commit: [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39736274225).
- [ ] Full CI for the latest `main` commit completes successfully, including web and Android builds; the prior run was cancelled when documentation was updated: [latest CI runs](https://github.com/isaacokubi/chatify/actions).
- [ ] Validate live billing-provider callbacks and renewals in a safe sandbox; unit tests cannot prove production payment delivery.
- [ ] Verify the deployed API is running the intended commit before enabling billing enforcement for real tenants.

## Policy reminder

Chatify's transaction commission remains disabled. Workspace setup fees and recurring subscriptions are the intended monetization path. Never mark a workspace payment successful based only on STK initiation or a client-side claim.
