# Verification record — 2026-10-22 (billing boundary)

## Scope

This change adds a regression test for the exact instant a workspace subscription's expiry plus configured grace period ends.

## Test added

- `workspace locks at the exact subscription-expiry-plus-grace boundary` in `server/src/workspace-billing-access.test.js`.
- Checks the workspace is accessible one millisecond before the grace-period boundary.
- Checks both the route-level billing gate and public marketplace billing helper lock access at the boundary itself.
- Added regression coverage for January 31 renewing to February 28, plus February 28 in a non-leap year and February 29 in a leap year renewing to March 31. The implementation now preserves month-end renewal dates while avoiding JavaScript date overflow.

## Verified CI evidence

The billing-boundary change was merged via PR #71 as `3102dc9a437b1555a9070645cba02af47efbcbfe`. The month-end renewal regression was subsequently added and expanded on `main`; the latest source commit containing the expansion is `a5462c09f4b4930485a27f970ff1077a498ddb85`. Its quality workflow passed, including 193 backend tests and Flutter analysis/tests. The most recent completed full CI before these server-only billing changes passed on `ba17852243221b6eef07ca8940f404fd40ef6ad1`; a full CI run for the newer source was initiated separately.

- [Full CI run for billing-boundary change — success](https://github.com/isaacokubi/chatify/actions/runs/39735038381)
- [Latest quality checks — success](https://github.com/isaacokubi/chatify/actions/runs/39739310021) — backend tests/syntax checks and Flutter analysis/tests passed on `a5462c09f4b4930485a27f970ff1077a498ddb85`; the backend suite reports 193 passed, 0 failed.
- [Full CI for the latest pre-renewal-fix baseline — success](https://github.com/isaacokubi/chatify/actions/runs/39737538095) on `ba17852243221b6eef07ca8940f404fd40ef6ad1`, including web and Android debug builds.
- [Latest `main` quality workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401343) on `04286915efc84a3ec53f27c09c7e5a355032cd8f`.
- [Latest `main` full CI workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401352) on the same SHA; backend and mobile jobs completed successfully, including web and Android debug builds.
- Backend: `npm ci`, dependency audit, `npm test`, `npm run lint`, backup/recovery script validation, and production-URI restore guard passed in full CI.
- Mobile: Flutter dependency resolution, analysis, tests, web build, and Android debug APK build passed in full CI.
- The latest source quality workflow is confirmed successful on `a5462c09f4b4930485a27f970ff1077a498ddb85`. The most recent confirmed full CI (including web and Android debug builds) is successful on `ba17852243221b6eef07ca8940f404fd40ef6ad1`. A full CI run was started for the newer source, but its web-build step had not completed at the time of this record; do not mark that newer full CI as passed without a successful run result.

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
- [x] Latest quality checks passed on the source commit containing the expanded month-end regression tests: [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39739310021); 193 backend tests passed, zero failed, and Flutter analysis/tests passed.
- [x] Full CI for latest `main` commit `04286915efc84a3ec53f27c09c7e5a355032cd8f` completed successfully, including backend and mobile jobs, web build, and Android debug APK: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39736401352).
- [x] Latest source quality workflow completed successfully: [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39739310021).
- [x] Full CI completed successfully on the previous source baseline: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39737538095). A newer full CI run must be independently confirmed before claiming web/Android build success for the month-end renewal fix.
- [ ] Run end-to-end Daraja sandbox tests for STK initiation, valid/invalid/duplicate callbacks, reconciliation, and subscription renewal/expiry; unit and CI tests cannot prove external payment delivery.
- [ ] Verify the deployed API is running the intended commit and validate real environment configuration before enabling billing enforcement for tenants.

## Policy reminder

Chatify's transaction commission remains disabled. Workspace setup fees and recurring subscriptions are the intended monetization path. Never mark a workspace payment successful based only on STK initiation or a client-side claim.
