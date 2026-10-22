# Verification record — 2026-10-22 (billing boundary)

## Scope

This change adds a regression test for the exact instant a workspace subscription's expiry plus configured grace period ends.

## Test added

- `workspace locks at the exact subscription-expiry-plus-grace boundary` in `server/src/workspace-billing-access.test.js`.
- Checks the workspace is accessible one millisecond before the grace-period boundary.
- Checks both the route-level billing gate and public marketplace billing helper lock access at the boundary itself.
- Added regression coverage for January 31 renewing to February 28, plus February 28 in a non-leap year and February 29 in a leap year renewing to March 31. The implementation now preserves month-end renewal dates while avoiding JavaScript date overflow.

## Verified CI evidence

The billing-boundary change was merged via PR #71 as `3102dc9a437b1555a9070645cba02af47efbcbfe`. The month-end renewal regression was expanded on `main`, and the full CI workflow completed successfully on commit `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`. The latest full CI confirms all automated backend and mobile checks passed for the repository state containing the renewal fix and this verification record.

- [Full CI run for billing-boundary change — success](https://github.com/isaacokubi/chatify/actions/runs/39735038381)
- [Latest quality checks — success](https://github.com/isaacokubi/chatify/actions/runs/39739597328) on `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`.
- [Latest full CI — success](https://github.com/isaacokubi/chatify/actions/runs/39739597321) on `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`, including backend, Flutter analysis/tests, web build and Android debug APK build.
- Backend suite in that full CI run: **193 tests, 193 passed, 0 failed**; dependency audit, lint/syntax checks and backup/recovery validations passed.
- [Latest `main` quality workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401343) on `04286915efc84a3ec53f27c09c7e5a355032cd8f`.
- [Latest `main` full CI workflow — success](https://github.com/isaacokubi/chatify/actions/runs/39736401352) on the same SHA; backend and mobile jobs completed successfully, including web and Android debug builds.
- Backend: `npm ci`, dependency audit, `npm test`, `npm run lint`, backup/recovery script validation, and production-URI restore guard passed in full CI.
- Mobile: Flutter dependency resolution, analysis, tests, web build, and Android debug APK build passed in full CI.
- **All automated CI checks are confirmed successful** on `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`: both quality and full CI workflows completed successfully, including web and Android debug builds. These results cover automated checks only; live payment-provider and deployed-production acceptance still require separate validation.

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
- [x] Latest quality checks passed: [quality checks](https://github.com/isaacokubi/chatify/actions/runs/39739597328) on `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`.
- [x] Latest full CI passed: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39739597321) on `951e4417b49e0afa40acdd92b2933b4ca2e4aff3`; backend, Flutter analysis/tests, web build and Android debug APK build all succeeded. Backend suite: 193 passed, 0 failed.
- [x] Full CI for latest `main` commit `04286915efc84a3ec53f27c09c7e5a355032cd8f` completed successfully, including backend and mobile jobs, web build, and Android debug APK: [full CI](https://github.com/isaacokubi/chatify/actions/runs/39736401352).
- [x] The month-end renewal fix has successful quality and full CI workflow results, including web and Android builds, linked above.
- [ ] Run end-to-end Daraja sandbox tests for STK initiation, valid/invalid/duplicate callbacks, reconciliation, and subscription renewal/expiry; unit and CI tests cannot prove external payment delivery.
- [ ] Verify the deployed API is running the intended commit and validate real environment configuration before enabling billing enforcement for tenants.

## Policy reminder

Chatify's transaction commission remains disabled. Workspace setup fees and recurring subscriptions are the intended monetization path. Never mark a workspace payment successful based only on STK initiation or a client-side claim.

## CI workflow reliability follow-up

The full CI workflow previously used `cancel-in-progress: true`, which could cancel verification when several commits were pushed close together. This was changed to `cancel-in-progress: false` in commit `448239c98a54bef49d9f05ec213a086aabde53b6`, so runs are serialized instead of cancelling the in-progress build. The quality workflow passed for that commit: [quality run](https://github.com/isaacokubi/chatify/actions/runs/39776344673). The associated full CI run was still in progress when this note was prepared: [full CI run](https://github.com/isaacokubi/chatify/actions/runs/39776344671). Do not mark that run passed until GitHub reports a successful conclusion.

