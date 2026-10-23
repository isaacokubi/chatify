# Local and remote reconciliation audit — 2026-10-23

## Scope and evidence

Repository path: `/home/camaraadmin/Desktop/isaac projects/dart/chatify`. The checked-out `HEAD`, `main`, and fetched `origin/main` all point to `4b170f7cbe3bc72373a98af475ec9448fba27566`; ahead/behind is `0/0`. The working tree was already a staged/unstaged recovery merge with `MERGE_HEAD=2a406cdb33de4ea7cd0688f097d247e235f1d1de` (parent `76c67a73502fa15aa37b04b085132f79b8f0d55b`). That operation remains open and untouched. The local-only staged and unstaged changes were preserved.

`git fetch --prune origin` succeeded. It discovered `origin/fix/flutter-memory-date-cache-tests-20261023` at `4bf404eab277ba058afbaecb5facbae36254c35d`. GitHub's API confirmed PRs #73, #72, #66, and #64 remain open. PR #73 is a draft with a clean mergeability report and one source file changed; its API description says Flutter analysis/tests were not run. PR #72 is open and contains a focused callback processor, callback tests, and bounded workspace-payment reconciliation. PR #66 and #64 are reported dirty/unmergeable. Their remote branch diffs against this checkout include thousands of lines and remove current server security, billing, queue, and business modules; they are not safe merge candidates as whole branches.

## Audit matrix

| Feature | Local implementation | Remote implementation | Tests/evidence | Discrepancy and required action | Status |
| --- | --- | --- | --- | --- | --- |
| Memory date parsing | `memoryDateFromText()` supports named explicit dates and `tomorrow`; exact calendar components are checked. Local candidate extraction attaches date/time. | PR #73 (`4bf404e`) adds the helper/accessor on one file; current local version includes surrounding changes. | Full Flutter suite: 30 passed; coverage includes tomorrow, year rollover, leap year, impossible dates, malformed dates, and unrelated numbers. | Add timezone-boundary coverage if the date-only serialization contract changes. | Implemented and locally verified. |
| Account-scoped GET cache | Secure-storage cache, same-account request coalescing, network/5xx fallback, seven-day expiry and successful-write invalidation. | PR #73 exposes `Api.cachedGet`; its branch had no test additions. | Full Flutter suite: 30 passed; includes expiry, account isolation, fallback and invalidation. | Expired legacy raw cache is deliberately discarded because it has no trustworthy timestamp. | Implemented and locally verified. |
| Offline messages | Encrypted request body and secure, per-account/conversation outbox; stable `clientMutationId`; pending UI state; retries after reconnect/history reload; server deduplication. Outbox writes/removals are serialized. | PR #66 includes a divergent offline startup implementation; its diff removes much newer code and cannot be merged wholesale. | Full Flutter suite: 30 passed, including concurrent enqueue/account-switch coverage. Server suite passed 208 tests. | No durable exponential retry schedule or cross-process lock; device restart/reconnection acceptance remains needed. Pending data remains scoped to the original account. | Partial; device acceptance remains. |
| Business offline records | Durable client queue for create operations on catalog items, customers and tasks; server validates IDs/base versions and records conflicts. | PR #66 changes the same client and server area but is dirty and divergent. | Server covers deterministic IDs, stale writes and business mutations; Flutter suite has limited queue coverage. | Client queue is in `SharedPreferences`, not secure storage; only creates are queued. Move private data to secure persistence before claiming privacy-safe offline support. Updates/deletes and cross-device conflicts remain unsupported. | Partial; privacy hardening required. |
| Contacts and Memories | Online authenticated APIs and secure cached GET reads. | No safe, targeted incoming branch identified. | Existing online tests; no durable create/update/delete outbox coverage. | Offline contact and Memory Card mutations are unsupported and must remain visibly pending/failed rather than appear synchronized. | Missing offline mutation support. |
| School records and fees | Online school records and fee workflows. Payment status remains pending until verification/callback; no general offline school mutation queue. | Recovery merge contains school-related local changes; PR #66 is not safe to merge wholesale. | Backend school tests exist; Flutter has learner/fee tests, but this run must establish final results. | No durable school create/update/delete queue or reopen/reconciliation test. Payments must stay outside ordinary queues. | Partial / online-only mutations. |
| Attachments and Sparks | Attachments are sent through API/provider flows; Spark media is selected and posted as request data. | Local staged/unstaged Spark feature work is not on `origin/main`. | Spark UI widget coverage exposed and fixed an action-label mismatch and a disposed-controller race. | No durable file outbox, upload retry or duplicate protection for offline attachments. | Online-only media; offline upload unsupported. |
| Notifications | Server notification outbox persists jobs with bounded retry/backoff and deduplication. | Current main contains notification queue implementation. | Backend notification queue/provider tests are in the full suite. | No evidence of user-visible durable per-notification pending/failed/retry state in the Flutter client. | Backend durable; client status partial. |
| Daraja callbacks | Existing route performs reference matching, amount/phone/receipt validation and conditional one-time state transition; provider/business payment tests cover core rules. | PR #72 extracts `processDarajaCallback`, adds deterministic callback tests and bounded workspace entitlement reconciliation. | Server suite passed 208 tests; PR #72 tests were inspected but not merged into this change. | The extracted PR helper and its regression suite are not present locally. Follow up separately; verify admin reconciliation authorization. | Payment safeguards present; PR delta remains open. |
| Startup/API efficiency | Existing client has cached startup reads, GET coalescing and async button support in current source. | PR #64 changes these areas but GitHub reports it dirty/unmergeable. | Flutter tests and analysis provide current local evidence; rerun outcomes below. | No whole-branch merge. Inspect individual changes only after full local verification. | Local implementation; PR unresolved. |
| Branch/merge state | Local worktree is on `recovery/merge-school-improvements-20261023` with the recovery merge in progress and the intended reconciliation changes present. | `origin/main` was equal to the merge's first parent before this delivery. | Fetch, branch ancestry and status inspected. | Conclude the existing merge with reviewed fixes, then fast-forward/push `main`; do not rewrite remote history. | Merge commit and Vercel deployment pending. |

## Checks run in this audit

| Command | Result |
| --- | --- |
| `git fetch --prune origin` | Passed; remote date/cache branch discovered. |
| `cd server && npm run lint` | Passed; configured `node --check` list completed. |
| `cd server && npm test` in restricted sandbox | 204 passed, 1 failed. Failure was loopback `listen EPERM` in the API-startup test. |
| `cd server && npm test` with loopback permitted | 205 passed, 0 failed, 0 skipped, 0 todo. |
| `cd mobile && flutter analyze` | Exit 1 with 27 informational diagnostics and no compilation errors or warnings; unused helper warning was removed. CI's `--no-fatal-infos` equivalent is still running. |
| `cd mobile && flutter test` | 30 passed, 0 failed. Initial stale Spark label and dialog controller lifecycle defects were repaired. |
| `cd mobile && flutter build web --dart-define=CHATIFY_API=https://chatify-api-c1eh.onrender.com` | Passed; JavaScript web build completed in 131.8 seconds. |
| `cd mobile && flutter build apk --debug` | Passed; debug APK produced at `build/app/outputs/flutter-apk/app-debug.apk`. |
| `cd mobile && dart format --output=none --set-exit-if-changed lib test` | Blocked by SDK cache write permission. `dart format lib test` completed and formatting was applied. |
| Focused concurrent secure-outbox test | Passed after serialization was added. |
| `cd mobile && dart format lib test` | Passed; formatted `main.dart`, `chatify_e2ee.dart`, and `widget_test.dart`. |

## Offline behavior and payment acceptance limits

Payments are never replayed as ordinary offline mutations. A provider timeout after initiation is uncertain and must remain pending until the server receives trusted reconciliation evidence. Unit tests and local builds cannot establish a live Daraja callback, production callback reachability, Atlas tenant isolation, or physical-device offline/restart behavior. No live payment or database operation was performed as part of this audit.

## Current delivery state

This is an audit and implementation record, not a production approval. Local server tests, Flutter tests, and web/debug APK builds passed. Informational analyzer diagnostics remain; live Daraja final callback, Atlas isolation, device offline/restart acceptance, and a signed production release remain external gates. Git merge/push and Vercel deployment status must be recorded after delivery.

## Continuation verification (2026-10-23)

This section records verification performed after the initial audit text above. It supersedes older test counts for the current source where they differ.

| Area | Result | Evidence and limits |
| --- | --- | --- |
| GitHub refs | `git fetch --all --prune` completed; `origin/main` remains `4b170f7cbe3bc72373a98af475ec9448fba27566`. | Ref inspection shows #73 candidate at `4bf404eab277ba058afbaecb5facbae36254c35d`, callback reconciliation candidate at `4733ec684648abf34535491d3e1e78b37a6c7214`, and offline-startup candidate at `be7a6b93ed2dd1b13b475da2639d5ce7a7426310`. `gh` is unavailable and direct GitHub page fetch failed, so latest PR state and CI links could not be independently refreshed. Existing audit notes #73/#72 open and #66/#64 dirty; treat those as prior observations, not a fresh API confirmation. |
| Working tree | Protected; no branch switch, commit, merge conclusion, or push performed. | Active branch is `recovery/merge-school-improvements-20261023`; `MERGE_HEAD=2a406cdb33de4ea7cd0688f097d247e235f1d1de`; one stash remains (`stash@{0}`). There are substantial pre-existing staged and unstaged modifications. |
| Backend | `cd server && npm run lint`: exit 0. `cd server && npm test`: exit 0, 208 passed, 0 failed, 0 skipped, 0 todo. | Full suite ran with loopback access for the API startup test. |
| Flutter | `cd mobile && flutter test --concurrency=1`: exit 0, 30 passed. `cd mobile && flutter analyze --no-fatal-infos`: exit 0, 24 informational diagnostics. `dart format lib/main.dart test/widget_test.dart`: exit 0, no files changed by the final formatting pass. | The default parallel Flutter test runner stalled at discovery in this environment and was interrupted before any tests ran. Serial execution completed. No test was skipped in the successful run. |
| Business workspace billing | Removed Business screen billing state, reads, checkout/polling code, and organization-switch billing requests. Added widget assertions that the Business screen shows no workspace billing/refresh control and issues no Business billing request. | Preserved platform-admin billing, backend billing/reconciliation routes, school billing, merchant POS, payment history, and other payment paths. Widget regression is included in the passing Flutter suite. |
| Logout and dark theme | Existing primary authenticated shell displays logout across Chats, Business, Contacts, Profile, School and Admin tabs. First-run dark mode and saved light preference are covered by widget tests. | Does not add logout to every nested pushed route; those routes remain under the authenticated navigation stack. |
| School and Sparks | Existing School responsive learner register/guardian contact coverage and Spark view tests passed. Added Spark viewer edge glitter with type-based accents, reduced-motion behavior, and a widget assertion. | This continuation did not implement all requested School tables, all guardian/payment relations, or the complete Spark status UX. |
| Performance | No comparable before/after startup or message-send measurement was made. | Do not infer latency improvements from passing functional tests. |
| Offline | Existing implementation/tests cover account-scoped cached reads and a durable encrypted text outbox with idempotent IDs. | Physical offline/restart/reconnect acceptance remains unrun. Contacts, Memory, School, and Business mutations are not comprehensively durable; attachments are not queued offline; payments are never automatically replayed. |
| M-Pesa | Backend mock/provider and payment regression tests are among the 208 passing tests. | No authorized live Daraja sandbox credentials/callback endpoint were exercised. Live acceptance is blocked; no production payment was sent. |

### Current acceptance matrix

| Requested area | Current classification | Remaining work |
| --- | --- | --- |
| Local/GitHub reconciliation | Partially verified | Remote refs fetched and candidate heads inspected. Refresh PR API state/CI once GitHub API access or `gh` is available. Keep the existing recovery merge open until the complete diff is reviewed. |
| Business billing UI removal | Implemented and locally verified | No further UI work; retain platform and school billing safeguards. |
| Startup/performance | Partially implemented, not benchmarked | Add reproducible startup/API/message timing methodology and before/after measurements. |
| Offline-first | Partial | Device airplane-mode tests, durable supported mutation queues, conflict UI, and account-disposition flow remain. Media uploads remain unavailable offline. |
| Sparks | Partial | Edge glitter is implemented and widget-tested; colors use image/video/text type accents and animation stops for reduced-motion. Verify shared-content media previews and implement/verify privacy controls and remaining status interactions. |
| School | Partial | Fees, receipts, attendance, and academic tables plus role-sensitive guardian fields need complete route-to-UI verification and tests. |
| Business module | Partial | End-to-end acceptance for every organization journey, permissions, and offline mutation type remains. |
| Last seen and mentions | Partially implemented | Existing server/client hooks need broader authorization, multi-session, notification, reconnect, and E2EE acceptance coverage. |
| M-Pesa | Automated local coverage only | Authorized sandbox initiation, public HTTPS callback delivery, reconciliation, and receipts need environment-backed acceptance. |

No PR was created and no branch was pushed. The pre-existing recovery merge and all local changes/stash are preserved. This checkout is not production-ready based on the evidence available here.
