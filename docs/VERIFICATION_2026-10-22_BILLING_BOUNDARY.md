# Verification record — 2026-10-22 (billing boundary)

## Scope

This change adds a regression test for the exact instant a workspace subscription's expiry plus configured grace period ends.

## Test added

- `workspace locks at the exact subscription-expiry-plus-grace boundary` in `server/src/workspace-billing-access.test.js`.
- Checks the workspace is accessible one millisecond before the grace-period boundary.
- Checks both the route-level billing gate and public marketplace billing helper lock access at the boundary itself.
- Added a second regression test to ensure monthly renewal from January 31 resolves to February 28 instead of overflowing into March.

## Verified CI evidence

The full **Chatify CI** workflow completed successfully on `main` at commit `04286915efc84a3ec53f27c09c7e5a355032cd8f`. The billing-boundary change was merged via PR #71 as `3102dc9a437b1555a9070645cba02af47efbcbfe`; the follow-up month-end renewal regression test was added in commit `dfe0ec01676fe835279ceda9dec0b81d9517890b`. The final documentation commit also has successful quality and full CI runs.

- [Full CI run for billing-boundary change — success](https://github.com/isaacokubi/chatify/actions/runs/39735038381)
- [Quality checks including month-end test — success](https://github.com/isaacokubi/chatify/actions/runs/39736274225) — backend tests/syntax checks and Flutter analysis/tests passed on `dfe0ec01676fe835279ceda9dec0b81d9517890b`.
- [Latest `main` quality workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401343) on `04286915efc84a3ec53f27c09c7e5a355032cd8f`.
- [Latest `main` full CI workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401352) on the same SHA; backend and mobile jobs completed successfully, including web and Android debug builds.
- Backend: `npm ci`, dependency audit, `npm test`, `npm run lint`, backup/recovery script validation, and production-URI restore guard passed in full CI.
- Mobile: Flutter dependency resolution, analysis, tests, web build, and Android debug APK build passed in full CI.
- Latest `main` quality and full CI workflows are now complete and successful. The two links above identify the exact commit tested.

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
- [x] Full CI for latest `main` commit `04286915efc84a3ec53f27c09c7e5a355032cd8f` completed successfully, including backend and mobile jobs, web build, and Android debug APK: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39736401352).
- [x] Latest `main` quality workflow completed successfully: [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39736401343).
- [ ] Run end-to-end Daraja sandbox tests for STK initiation, valid/invalid/duplicate callbacks, reconciliation, and subscription renewal/expiry; unit and CI tests cannot prove external payment delivery.
- [ ] Verify the deployed API is running the intended commit and validate real environment configuration before enabling billing enforcement for tenants.

## Policy reminder

Chatify's transaction commission remains disabled. Workspace setup fees and recurring subscriptions are the intended monetization path. Never mark a workspace payment successful based only on STK initiation or a client-side claim.
