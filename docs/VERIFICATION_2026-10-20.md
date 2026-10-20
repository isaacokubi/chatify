# Verification record — 2026-10-20

This is a dated record of checks actually run for the Chatify repair and demo seed. Use it to avoid repeating unchanged work while iterating. A result applies only to the source state that was tested; rerun checks for affected files after changing them, and run the full backend suite before a release or merge.

## Passed checks

| Check | Result | Evidence |
| --- | --- | --- |
| Backend tests: `cd server && npm test` | **152 passed, 0 failed, 0 skipped** | Node test runner summary; includes API startup and seed configuration/session tests. |
| Backend syntax/lint: `cd server && npm run lint` | **Passed** | All configured `node --check` entries completed. |
| Seed and config syntax | **Passed** | `node --check src/seed.js` and `node --check src/seedConfig.js`. |
| Dependency inventory: `cd server && npm ls --depth=0` | **Passed** | All declared top-level dependencies resolved. |
| Flutter analysis: `cd mobile && flutter analyze` | **Passed, no issues found** | Analyzer completed after SDK cache access was approved. |
| Flutter tests: `cd mobile && flutter test` | **17 passed** | Includes all 4 `reply_test.dart` cases and 13 widget/unit cases. |
| Android debug APK: `cd mobile && flutter build apk --debug` | **Passed** | `mobile/build/app/outputs/flutter-apk/app-debug.apk` built successfully. |
| Seeder dry run: `cd server && npm run seed -- --dry-run` | **Passed, no writes** | Reported 8 accounts and Chats, Business, Stores and Schools; made no database connection. |
| Demo seed and integrity verification | **Passed** | Latest successful repeat reconciled 30 stable records, found 30/30, and reported 0 broken relationships. A subsequent repeat created 0 duplicate records. |
| Seeded account login API | **8 of 8 passed** | Each account authenticated through local `POST /api/auth/login`; response identity, active state, expected platform role and token presence checked. Token values were not recorded. |
| Diff whitespace check | **Passed** | `git diff --check` and staged equivalent. |

## Backend test suites included in `npm test`

All 31 test files below passed as part of the 152-case backend run:

- `server/src/auth.test.js`
- `server/src/business-customer-import.test.js`
- `server/src/business-customer-portal.test.js`
- `server/src/business-enterprise.test.js`
- `server/src/business-entitlements.test.js`
- `server/src/business-integrations.test.js`
- `server/src/business-marketplace.test.js`
- `server/src/business-pos.test.js`
- `server/src/business-public-api.test.js`
- `server/src/business-reviews.test.js`
- `server/src/business-search.test.js`
- `server/src/business-sla.test.js`
- `server/src/business-startup.test.js`
- `server/src/business-statements.test.js`
- `server/src/business-subscriptions.test.js`
- `server/src/business.test.js`
- `server/src/config.test.js`
- `server/src/conversation-visibility.test.js`
- `server/src/e2ee.test.js`
- `server/src/memory.test.js`
- `server/src/payments.test.js`
- `server/src/school.test.js`
- `server/src/service-status.test.js`
- `server/test/candidate.test.js`
- `server/tests/auth.test.js`
- `server/tests/config.test.js`
- `server/tests/core.test.js`
- `server/tests/lifecycle.test.js`
- `server/tests/payments.test.js`
- `server/tests/providers.test.js`
- `server/tests/seed.test.js`

Coverage includes authentication and session revocation, configuration guards, Business permissions and data workflows, storefront and POS validation, payment callbacks, school membership isolation and academic records, chat visibility and memory behavior, provider boundaries, API startup, and seeder safety.

The 17 Flutter cases cover reply lookup, readable API errors, cached reads, secure per-account conversation storage, secure offline mutations, preserving login tokens during temporary failures, Kenyan phone normalization, socket message/payment merging, sign-in and registration screens, admin dashboard sections, device-token deletion, and payment card display.

## Seeded database snapshot

The selected database label was `chatify`; it was confirmed for this run through the explicit unclassified-database acknowledgement. The seeder remains additive, refuses a production-named database, and never drops collections. See [the demo setup and cleanup notes](DEMO.md).

| Module | Records verified |
| --- | --- |
| Accounts | 8 active managed demo users: 1 platform admin and 7 regular users with module memberships. All 8 passed HTTP login. |
| Chats | 2 conversations, 3 messages, 2 saved contacts, 1 Memory Card. |
| Business and Stores | 2 organizations, 4 catalogue items, 1 customer, 1 sample order document, 1 task. No payment was initiated. |
| Schools | 1 workspace, 3 memberships, 2 students, 2 attendance records, 2 assessments, 1 announcement, 1 conference, 1 pending fee record. The fee is not a payment received. |

The full account register is [server/DEMO_ACCOUNT_REGISTER.md](../server/DEMO_ACCOUNT_REGISTER.md). On the last successful repeat, the seed reported all 30 non-user records as updated and created none, confirming stable-key idempotency. The initial rollout included retrying a seed after fixing an integrity mismatch; the final report reflects the reconciled records, not an assumption that the first attempt was atomic.

## Blocked or not verified

- `flutter build apk` (release) was attempted and blocked because Android signing variables are not configured. The debug APK build passed.
- Browser/device end-to-end navigation across all four modules was not run. The login API and database relationships were verified; Flutter widget/unit tests passed.
- Production deployment, production database state, and production payment providers were not tested.

## Avoiding duplicate test runs

Before repeating a check, compare the changes with the files and modules listed above. If a later change only affects the seed guard, run `server/tests/seed.test.js`, seed syntax/lint, a dry run, and (when database access is authorized) the repeatable seed/integrity/login verification. For UI changes, run `flutter analyze` and the relevant Flutter tests. Run `npm test` for backend behavior changes and before publishing a release. Do not treat an older pass as valid after its covered source changes.
