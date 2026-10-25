# M-Pesa testing and evidence boundaries

## Verification update — 2026-10-26

### Current automated evidence

- `cd server && npm test`: **236 passed, 0 failed, 1 skipped**, exit 0. The skipped test is the guarded MongoDB integration test when no test URI is provided.
- `cd server && npm run lint`: exit 0.
- Focused payment/provider, school and POS test files passed before the complete suite.
- `CHATIFY_MONGO_TEST_URI=mongodb://127.0.0.1:27018/chatify_audit_test_20261026 node --test --test-reporter=spec src/database.integration.test.js`: **1 passed, 0 failed, 0 skipped**, exit 0. It used a newly named audit database and the test dropped that database in teardown. The integration exercises synthetic requests and callbacks against the actual API and Mongo persistence; it is not a Daraja transaction.

The first full-suite attempt inside the restricted shell failed because the sandbox denied the API startup test's socket bind. Rerunning with local socket access passed. On this date, the shell had none of the platform, school, or POS Daraja environment variables set. This only establishes what was available to this local run; hosted environment values and deployed callback reachability were not inspected. No provider request was sent. Do not repeat the earlier 2026-10-25 OAuth check as current evidence.

### Implemented flows and evidence boundary

| Flow | Implemented path | Latest verification |
|---|---|---|
| Chatify Pay / platform STK | Authenticated request creates a durable attempt; Daraja callback uses `/api/payments/daraja/callback/:token`; participant status/reconciliation and bounded background queries exist. | Automated unit and isolated Mongo/API tests; **one historical manual KSh 1 sandbox end-to-end transaction on 2026-10-25** is recorded below. No production transaction was tested. |
| School fees and donations | School-scoped fee/donation records; per-school encrypted credentials; callback at `/api/schools/daraja/callback/:token`; receipt and fee balance update on confirmed or audited manual review. | Automated unit and isolated Mongo/API synthetic callback, receipt and balance tests. No school-specific Daraja transaction is documented. |
| Merchant POS/storefront STK | Merchant-specific encrypted credentials and shortcode; callback at `/api/business/pos/stk/callback/:token`; orders/charges remain pending until matching callback. | Automated route/database callback tests and POS unit tests. No merchant Daraja transaction is documented. |
| POS C2B | Token-protected `/api/business/pos/c2b/confirmation/:token`; matches destination, amount, receipt and sale reference. Safaricom callback registration is external configuration. | Synthetic API/database confirmation and duplicate tests only; no provider registration or delivery check. |
| Safaricom Dynamic QR | Daraja generates an M-Pesa-readable QR for the merchant shortcode; the sale remains pending until a matching C2B callback or authorized manual reconciliation. | Deterministic provider request/validation tests; no QR payment or provider confirmation end to end. |
| Bank transfer / other M-Pesa | Bank transfer remains a manual school workflow. No B2C transfer API is present. | No B2C capability claimed. |

### Configuration and callback requirements

Platform sandbox/live STK uses `MPESA_ENV`, `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_SHORTCODE`, `MPESA_PASSKEY`, `MPESA_CALLBACK_TOKEN`, and `MPESA_CALLBACK_URL`; `MPESA_TRANSACTION_TYPE` is optional. Set the callback URL to the public HTTPS route whose final path contains the same minimum-32-character random token. Safaricom callback authenticity is not established by a documented signature in this implementation; the high-entropy path token, exact stored provider IDs, amount/phone/receipt checks and idempotent update are the implemented controls. Redact callback paths from access logs.

School callback routing uses `PUBLIC_API_URL`, `SCHOOL_DARAJA_CALLBACK_TOKEN`, and `SCHOOL_PAYMENT_ENCRYPTION_KEY`; each school supplies its own authorized shortcode and Daraja credentials. Merchant POS uses `POS_STK_PUBLIC_BASE_URL`, `POS_STK_CALLBACK_TOKEN`, and `POS_DARAJA_ENCRYPTION_KEY`; the authenticated merchant setup stores shortcode-specific Daraja credentials encrypted at rest. POS C2B uses `POS_C2B_CALLBACK_TOKEN` and optional `POS_C2B_ALLOWED_IPS`. C2B URL registration/validation with Safaricom must be completed outside this application. Keep these settings in the deployment secret manager; never paste secret values into this document, test output, or source control. The environment values themselves are unset in the current local shell. No hostname or public route reachability conclusion can be made from that fact.

### Repeatable sandbox acceptance

1. Deploy an isolated non-production API with a sandbox-eligible shortcode/app and approved test phone. Set the required platform variables above in the private runtime environment. Confirm that startup/configuration succeeds without printing credentials.
2. Confirm DNS resolves and HTTPS reaches the API from outside the deployment network. POST to the exact callback path with a wrong token in an isolated test environment and confirm it is rejected; do not expose the valid token in logs.
3. Create a small sandbox STK payment through the application. Record only a redacted payment ID and time. An accepted initiation must remain `PENDING`.
4. Complete or cancel the sandbox prompt. Verify trusted callback delivery, final backend status, `confirmationSource=provider_callback` (or the flow-specific callback source), and persisted provider receipt through an authorized server/database view. Never use a client message or screenshot as payment confirmation.
5. For safe replay testing, use synthetic callback fixtures/database tests, not a second provider charge. Replay the same callback serially and concurrently; verify one terminal update, one receipt, one balance/order effect. Test cancellation/failure, malformed values, wrong IDs/amount/phone/token, delayed callbacks, query timeout, unknown checkout ID, and reconciliation separately. Keep unresolved outcomes pending for review; do not retry an uncertain charge.
6. For C2B/Dynamic QR, verify external Safaricom callback registration first, then independently record callback delivery and exact reference/amount/shortcode matching. The platform STK result does not establish these paths.

For production rollout, verify merchant/school authorization, secret rotation/backup, callback DNS/TLS and redacted access logging, provider callback configuration, bounded reconciliation alerts, duplicate receipt handling, statement-to-record settlement, and a documented manual review owner. Sandbox success does not establish production settlement. Reconcile provider statements to persisted receipts and investigate unmatched transactions before closing a period.

### Evidence carried forward

The previously documented manual **KSh 1 Daraja sandbox STK payment on 2026-10-25** remains historical evidence: prompt reached the approved test phone, the payment was completed, result code `0` was observed, the callback was processed, status persisted as `SUCCESS`, and a provider receipt was recorded with source `provider_callback`. It is not repeated in this run, does not establish live-money settlement, and does not independently verify school, POS, C2B, or Dynamic QR. Older notes below are dated snapshots and should be read with this update.

## Latest recovery continuation (2026-10-25)

Sandbox check in the current continuation: sandbox mode and the consumer key/secret, shortcode, passkey, and callback URL are configured in ignored `server/.env`; the callback authentication token is absent. Callback URL is HTTPS, but the expected tokenized path cannot be validated, and DNS lookup for its host failed. Do not infer reachability from a configured URL. The user supplied an approved sandbox test phone; no STK request was sent because the callback receiver is not safe/ready. A redacted OAuth request to the sandbox endpoint returned HTTP 200 and an access token was present. This confirms OAuth only, not STK/callback/payment settlement.

The implementation has no separate `MPESA_API_URL` or status-query endpoint setting: `MPESA_ENV=sandbox` selects `https://sandbox.safaricom.co.ke` for OAuth, STK Push and STK status query. Status query uses the same shortcode/passkey and requires a known checkout request ID. `MPESA_TRANSACTION_TYPE` is optional and defaults to `CustomerPayBillOnline`.

Platform STK initiation now creates a durable attempt record before contacting Daraja. The attempt records its authenticated initiator, intended amount/currency/reference, timestamps and non-sensitive state history. Explicit failures before STK submission and provider rejections are distinguished from uncertain network/response outcomes. Uncertain outcomes remain `PENDING` with `REQUIRES_REVIEW`; an interrupted in-progress attempt is moved to review after 45 seconds. The service will not automatically submit another STK prompt for an uncertain attempt.

If a Daraja `CheckoutRequestID` was durably received, the existing authenticated reconciliation path can query status with the configured environment and shortcode, bounded attempts and backoff. Query responses without complete callback evidence do not confirm success. The implemented query requires `CheckoutRequestID`; this code does not implement a documented lookup by `AccountReference` or `MerchantRequestID`. If the checkout ID was lost, the payment remains pending and must not be retried. An authorized platform administrator must inspect the provider portal/statement and use the audited manual-review workflow, or escalate to Safaricom with the stored payment reference, time, amount and payer details. Provider evidence must establish the actual transaction; a screenshot/client assertion alone is insufficient.

The platform review endpoint is administrator-only, limited to reviewable self-STK payments and excludes workspace billing/business side effects. It validates exact amount/currency, payer, configured shortcode, deterministic account reference, transaction time, provider receipt, evidence type/reference and reviewer reason. A database compare-and-set prevents concurrent application, and the provider receipt unique index prevents duplicate receipt assignment. The stored source is `manual_review`, distinct from `provider_callback`; a later callback must match receipt and original transaction fields before source is upgraded. Conflicts return an error without undoing a manual record. Private evidence fields are selected only for the administrator response. School fee manual verification remains school-admin/staff scoped, validates the tenant payment and amount/reference, records reviewer/time/evidence/reason, preserves history and labels receipts as manually reviewed rather than callback-confirmed.

Latest local results: ordinary backend **233 passed, 0 failed, 1 skipped**; disposable MongoDB full backend run **234 passed, 0 failed, 0 skipped**; focused payment/school/POS files **4 passed**; callback/reconciliation concurrency and school balance/receipt integration assertions passed against synthetic records on disposable MongoDB. These are local mocks/simulation, not genuine Daraja transaction evidence. A previous sandbox OAuth request returned HTTP 200, but no STK initiation or provider-delivered callback has been verified. No approved sandbox phone and safe public isolated callback endpoint were available. Keep that external gate BLOCKED.

Chatify contains several Daraja-related paths: platform Chatify Pay STK requests (`server/src/payments.js`), school fee and donation STK/callback handling (`server/src/school.js`), merchant POS and storefront STK/callback handling (`server/src/business-pos.js`), Safaricom Dynamic QR generation, and a token/IP-restricted POS C2B confirmation callback. Platform and school callback URLs now require distinct random path tokens; tokens must be configured in server secrets and redacted from proxy/access logs. Manual bank transfer is not a Daraja flow. No B2C payout/transfer flow was found in the current implementation.

## Safe test levels

1. **Unit/mock:** run `cd server && npm test`; provider mocks validate local state transitions only. A mock result is not a Safaricom transaction.
2. **Sandbox:** configure a non-production API with Safaricom sandbox credentials in its private environment, use a sandbox-eligible number and public HTTPS callback, then record initiation response, provider callback delivery and resulting persisted reference/status. An accepted STK request remains pending until the trusted callback is validated. Redact phone numbers, credentials, access tokens and sensitive callback fields in evidence.
3. **Production configured, not live tested:** document configuration/approval evidence without claiming settlement capability verified.
4. **Live settlement:** not performed unless the user explicitly authorizes the exact test amount and source/destination context. Never request secrets in chat.

## Current status

The test levels are intentionally separate. Unit/provider tests use deterministic transports. `server/src/database.integration.test.js` runs the actual API callback routes and Mongoose persistence on a no-volume ephemeral MongoDB 7 instance at loopback, database name `chatify`, using synthetic records and local test-only callback tokens. The final disposable-database full backend run passed **233 tests, 0 failed, 0 skipped**, including the API integration case (68 seconds). It covers platform and school status reconciliation, the bounded automatic platform sweep, platform/school/merchant STK callbacks, wrong token/amount rejection, duplicate/concurrent callbacks, school receipt and fee balance, and merchant attribution. That is application/database simulation, not a provider transaction. A separately launched isolated integration invocation reported its API test as passed but was interrupted because its runner remained alive after the test; rely on the clean full-suite database run for the final pass result.

On 2026-10-25 a genuine token-redacted Daraja sandbox OAuth request returned HTTP 200 and an access token. The token was not logged or persisted. No STK request was sent: the ignored local `.env` has no `MPESA_CALLBACK_TOKEN` and its callback URL is not configured with the required tokenized route; no approved sandbox phone or isolated public callback endpoint was available. Therefore provider-delivered callback, final provider confirmation, provider-generated receipt, and external balance reconciliation remain unverified. No real funds were used. This document does not certify Safaricom approval or production connectivity.

The API now exposes authenticated bounded status queries at `POST /api/payments/:id/reconcile` for payment participants and `POST /api/schools/:schoolId/fees/:paymentReference/reconcile` for school administrators/staff. Platform payments are also swept in the background: only initiated records at least two minutes old are eligible, at most two are queried per minute, and the same atomic claim, five-attempt cap, and 1/2/4/8/16 minute backoff apply. School queries remain staff-triggered because each school has separate encrypted credentials and shortcode. Query success without callback amount, payer phone and receipt evidence remains pending and requires an actual provider callback or authorized school staff verification against independently obtained evidence. Definitive provider failure/cancellation can be recorded once; ambiguous responses and transport errors remain pending. Elapsed time alone never expires a payment. No platform manual-confirm endpoint exists; unresolved platform transactions that cannot be queried require an operator/provider reconciliation procedure before production.

The Daraja query implementation uses the same mode-specific host and cached OAuth token as STK initiation, checks the returned checkout ID when present, and retains a redacted outcome history. A status-query `ResultCode=0` does not issue a receipt because Daraja query responses do not supply the complete callback metadata needed by this application. Historical payments without a recorded shortcode cannot be queried automatically and require manual reconciliation.

| Simulated scenario | Local evidence | Boundary |
|---|---|---|
| OAuth success, rejection, malformed JSON, expiry/refresh; STK acceptance/rejection, Dynamic QR request | Deterministic `createDarajaProvider` transport tests; separately, token-redacted genuine sandbox OAuth | Sandbox OAuth genuinely returned HTTP 200. Mocked STK acceptance only returns provider references; no external STK request |
| Success, customer cancellation (1032), other provider rejection, malformed result, wrong amount/phone, missing receipt | `buildDarajaPaymentTransition` and `resolveCallbackOutcome` tests | Synthetic callback fixtures; not provider-delivered |
| Duplicate/replay and two concurrent success callbacks | In-memory compare-and-set unit test and Mongo API integration through actual platform/school/POS callbacks | DB integration confirms one terminal payment/receipt and no duplicate school ledger entry for concurrent/replayed callbacks; process restart with pending callback remains untested |
| Unauthorized/incorrect callback token and callback URL configuration | Platform/school/POS STK/C2B route assertions plus configuration regression tests | Wrong local token is rejected; public provider callback delivery and source IP/signature proof remain unavailable |
| Fee balances and pending/failed/cancelled payment treatment | `school-fees.test.js` and persisted school fee API/callback integration | Pending and cancelled payments leave KSh 10,000 charge unpaid; confirmed KSh 3,000 creates receipt, paid KSh 3,000 and remaining KSh 7,000; duplicate does not alter it again |
| POS amount/phone/receipt mismatch and failure/cancellation | `business-pos.test.js` plus persisted merchant STK/C2B routes | Wrong amount does not settle; concurrent duplicate produces one successful charge/receipt, merchant attribution remains correct. No live provider event |
| Query success, pending/ambiguous response, failure/cancellation, timeout, malformed JSON, bounded retry, lost callback, cross-user access | Deterministic Daraja transport tests and disposable Mongo API acceptance for platform/school query routes and the bounded platform sweeper | Simulated provider only; actual callback evidence is still required for success. Durable recovery after a process restart is limited to persisted pending records and sweep eligibility; refunds and reversals are not implemented |

## Sandbox procedure

Use an isolated database and non-production API. Follow [M-PESA-DEPLOYMENT.md](M-PESA-DEPLOYMENT.md) for environment names and public callback setup. Before initiating, verify the environment is sandbox, callback resolves to the intended test API, amount/phone are expected, and database is disposable. Capture redacted timestamps, provider request/response IDs, persisted pending record, callback delivery result and final state. Repeat with duplicate callback and provider failure/cancellation where supported. Do not manually inject fabricated success callbacks and call them provider evidence; synthetic callback payloads belong only in automated unit tests.

## Flows requiring separate evidence

| Flow | Code area | What acceptance must show | Current status |
|---|---|---|---|
| Chatify Pay STK | `payments.js` / provider adapter | OAuth/STK request; pending before token-authenticated, matched callback; idempotent terminal state | Genuine OAuth PASS; STK initiation and provider callback BLOCKED by callback configuration and missing approved sandbox phone/isolated callback target. Status query is implemented/tested with mocks; query success remains pending until callback receipt evidence |
| School fee STK | `school.js` | School shortcode/request matching; token-authenticated callback; student mapping; one confirmed ledger item; correct receipt/balance | Local callback and authenticated status-query routes tested; query success remains pending. Full provider sandbox blocked |
| Merchant POS STK | `business-pos.js` | Merchant-owned credentials/destination; pending charge; callback matched to merchant and amount; no cross-tenant settlement | Local automated tests PASS; sandbox blocked |
| Merchant POS C2B | `business-pos.js` | Token/IP-restricted callback, till/paybill reference and amount match, idempotent charge confirmation | Local automated suite PASS; external C2B callback not verified |
| Dynamic QR | `payments.js`, `business-pos.js` | Provider-issued QR for the configured merchant and correct amount/reference; payment remains pending until reconciliation | Local request tests only; scan/settlement not verified |
| B2C payout/transfer | No route/provider flow found | Do not claim supported | Not implemented/NOT APPLICABLE |

## MongoDB API integration scenarios

Executed in the final full suite with `CHATIFY_MONGO_TEST_URI=mongodb://127.0.0.1:27018/chatify npm test`. The URI was restricted in test code to a loopback MongoDB server at port 27018 and a disposable Chatify database. The container had no persistent volume and used synthetic identities only. Actual route assertions cover platform STK callbacks, school fee callbacks and receipt/balance lookup, merchant POS STK callbacks, POS C2B confirmation, owner/parent school authorization, and scoped contact/memory/Spark deletes. Callback contents were synthetic fixtures; provider authenticity is not inferred.


## Recorded manual sandbox acceptance — 2026-10-25 (latest evidence)

This section records the successful controlled test reported and verified in the Codex work session, and supersedes earlier statements in this file that said no STK request had ever been completed. During that successful test:

- A Daraja sandbox STK prompt arrived on the test phone.
- The user entered the payment PIN and completed a **KSh 1** sandbox payment.
- Daraja's result was success (result code `0`).
- Chatify processed the provider callback; the stored confirmation source was `provider_callback`.
- The payment status was updated and persisted as `SUCCESS`, and a provider receipt was present.
- Recorded transaction reference: `a3c55d8d-836e-4e5c-ab86-3e527b5f1372`.

**Conclusion:** one end-to-end Daraja **sandbox** payment is confirmed, including prompt delivery, user completion, callback processing and persisted terminal status. This is stronger evidence than OAuth or mocked callback tests alone. It does not establish production-mode credentials/approval, live-money settlement, or separate end-to-end acceptance for every school fee, merchant POS, C2B or QR flow.

The later disposable MongoDB acceptance run also passed payment callback, school fee receipt/balance and scoped deletion assertions using synthetic test callbacks. During that run, a separate `stk_transport` failure was logged while testing an error path; the suite still passed. Treat this as a distinct failed/uncertain attempt, not as evidence that the successful KSh 1 transaction failed. For transport/ambiguous outcomes, Chatify must retain a pending/review state and avoid automatically sending a duplicate STK prompt.

| Gate | Latest status | Evidence boundary |
|---|---|---|
| Daraja sandbox OAuth | PASS | Sandbox authentication had returned HTTP 200 in the earlier redacted check. |
| Sandbox STK prompt and payment | **PASS — one KSh 1 test** | User received prompt and completed payment. |
| Provider callback and persisted success | **PASS — recorded transaction** | Result code 0, `provider_callback`, persisted `SUCCESS`, provider receipt present. |
| Automated callback/fee/receipt/balance integration | PASS | Disposable MongoDB test with synthetic callbacks; separate from the manual provider transaction. |
| Live production M-Pesa settlement | NOT VERIFIED | No production-mode transaction is claimed. |
| All school/POS/C2B/QR provider paths | NOT VERIFIED end to end | Each has separate configuration and acceptance requirements. |
