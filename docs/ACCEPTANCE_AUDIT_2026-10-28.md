# Chatify acceptance audit — 2026-10-28

## Scope and evidence boundary

Repository: `isaacokubi/chatify`  
Branch reviewed: `main`  
Source commit reviewed: `0a21f686826286d04d35795e540dc467def6e883`  
Audit date: 2026-10-28

The latest GitHub Actions runs associated with this commit completed successfully:

- [Chatify CI](https://github.com/isaacokubi/chatify/actions/runs/40668439993): backend and mobile jobs passed. The workflow runs dependency audit, backend unit tests/lint, restore-script safety checks, Flutter analysis/tests, Flutter web build, and Android debug APK build.
- [Chatify quality checks](https://github.com/isaacokubi/chatify/actions/runs/40668440051): backend syntax/tests and Flutter analysis/tests passed.
- [Android debug APK build](https://github.com/isaacokubi/chatify/actions/runs/40668440069): build completed successfully.
- GitHub's [Vercel status](https://vercel.com/isaacokubis-projects/chatify-mobile/ENRJoNn69YgKbZztoPGaGnuEr72A) for the commit reports success.

This environment could not resolve/reach the deployed Render API hostname during this audit. Consequently, the latest live API health, live login for the demo accounts, and live Vercel UI were **not independently exercised in this run**. CI green is evidence of source/build checks, not a substitute for authenticated hosted acceptance. Historical counts in `TEST_RESULTS.md` refer to the commits and runs explicitly named there; do not attribute them to this commit unless the linked logs say so.

## Demo-account acceptance

The following account identities were supplied for a controlled demo acceptance run. The shared password is intentionally not stored in this repository or this report.

| Login email | Intended access |
|---|---|
| `admin@demo.chatify.test` | Platform administrator |
| `alice@demo.chatify.test` | Chat demo user |
| `brian@demo.chatify.test` | Chat demo user |
| `nia@demo.chatify.test` | Business and store owner |
| `sam@demo.chatify.test` | Business and store manager/owner |
| `grace@demo.chatify.test` | School administrator |
| `peter@demo.chatify.test` | School staff member |
| `miriam@demo.chatify.test` | School parent/guardian |

Run the read-only authenticated smoke test from `server/` with the password injected as an environment variable by a private terminal or CI secret manager:

```sh
CHATIFY_API_URL=https://chatify-api-c1eh.onrender.com \
CHATIFY_DEMO_PASSWORD='(inject privately; do not save in shell history)' \
node scripts/demo-account-smoke.mjs
```

Prefer setting the secret in a protected environment rather than putting it literally in a command. The script never prints the password or response bodies. It checks each login, returned identity and platform role, then read-only profile, contacts, conversations, payment list, school list and business list endpoints. It also checks that the administrator can read the admin overview and all non-admin accounts receive HTTP 403. Authentication updates the account's `lastSeen` timestamp; the script does not create or modify chats, contacts, business/school records or payments.

**Execution status for this audit:** the script is provided for repeatable acceptance, but it was not run against the hosted API here because the network runtime could not resolve the Render hostname. Do not mark the account matrix passed until the script has been run from a network that can reach the service and its output has been reviewed. It covers API smoke only, not full UI or websocket behavior.

## Module acceptance gates

| Module | Automated evidence | Hosted acceptance still required |
|---|---|---|
| Chat | Backend/Flutter CI passes | Two-account message send/receive, attachments, group membership, reactions/read receipts, reconnect, websocket presence, blocking and expiry behavior |
| Business/catalogue/store | Business API regression tests pass | Nia/Sam owner/manager scope, create/edit/delete catalogue product, image upload/view, storefront enquiry/checkout, POS and tenant isolation |
| Contacts | Existing Flutter/backend tests pass | Add/search/remove, block/unblock, direct conversation and contact visibility using Alice/Brian |
| Profile/auth | Auth tests and CI pass | All eight demo logins, profile update, password/session behavior, account status, and role authorization on hosted API |
| School | School and payment regression tests pass | Grace/Peter/Miriam access boundaries; student attachment, fee structures, attendance, academics, inbox filters, fee receipt and downloadable parent/admin receipts |
| Admin | Server-side role middleware and admin tests exist | Admin overview/users/payments and backup screens in browser; verify every non-admin receives 403 for protected routes |
| Voice/video | Signaling/ICE tests and Android build pass | Two physical devices, camera/microphone permissions, TURN/network traversal, call end/reconnect and blocked-user behavior |
| Backup/recovery | Shell syntax and production-target refusal tests pass | Perform encrypted off-site backup and restore into an isolated database, then verify counts/checksums; never run a restore against production |

## M-Pesa acceptance and known gaps

No M-Pesa transaction, STK prompt, callback or live-money movement was initiated during this audit. A successful unit test or a mock result is not provider acceptance.

| Flow | Current evidence/status | Required gate before claiming ready |
|---|---|---|
| School fee STK | Automated regression coverage for payment state, callback/query matching, receipt/balance and duplicate protection; no new hosted provider acceptance in this audit | Use approved school sandbox credentials and a supported test number; verify initiation → callback → provider query → exactly-once fee balance and receipt update; exercise cancel/timeout/duplicate/wrong amount |
| School external Paybill/Till/manual verification | Manual review path exists; no automatic confirmation from a screenshot/reference alone | Verify the transaction against the authorized provider statement/trace and confirm school admin authorization |
| School donations | Automated success/failure/duplicate-event tests; no provider delivery acceptance | Sandbox donation with school-owned credentials, callback/query verification and receipt/accounting checks |
| Business POS STK | Merchant-scoped provider logic and automated tests exist; merchant provider setup/callback delivery not verified | Merchant's own approved Daraja app/shortcode, encrypted credentials, HTTPS callback and sandbox provider-confirmed settlement |
| Business POS C2B Paybill/Till | Synthetic matching/idempotency tests; URL registration/delivery unverified | Register callbacks in Daraja and prove an actual sandbox confirmation is matched to the correct merchant, reference, amount and unique receipt |
| Dynamic QR | Prior sandbox attempt returned HTTP 401 (authorization/product entitlement unresolved) | Confirm product entitlement/credentials with Safaricom and complete provider acceptance |
| Business invoice STK | Real-provider path is guarded and returns HTTP 409 until merchant-scoped invoice settlement is implemented | Implement and test merchant-scoped invoice settlement; do not route a merchant invoice through the platform shortcode |
| Storefront order settlement | Platform-shortcode settlement is intentionally blocked (HTTP 409); merchant-scoped settlement not implemented | Implement merchant-scoped order payment and reconciliation before accepting real online orders |
| Person-to-person | Current contact action hands off to Safaricom's `*334#`; no Chatify-confirmed transfer state or in-app provider receipt | This is not a Chatify transfer service. Keep it explicitly labelled as external handoff, or separately implement an approved provider-supported disbursement/transfer product with callbacks, audit controls and explicit authorization |
| Refund/reversal | Automated provider refund/reversal lifecycle not implemented | Define and implement provider-supported reversal workflow and reconciliation before advertising automatic refunds |

## Operational release blockers

1. Confirm Render's current deployed SHA, `NODE_ENV`, `MPESA_ENV`, database readiness and current callback settings using authorized hosting controls.
2. Rotate any previously exposed Daraja keys, passkey or callback tokens after reconciling pending transactions; never commit replacements.
3. Run the demo-account smoke script against the reachable hosted API and save its sanitized output as release evidence.
4. Complete the browser and two-device checks above.
5. Complete provider-approved sandbox acceptance for each payment type; do not use live money as a substitute for a sandbox test.
6. Implement merchant-scoped settlement for business invoices/storefront orders and decide whether the P2P feature is only an external handoff or a future provider-backed transfer product.
7. Complete a safe off-site backup and isolated restore drill.

## Verdict

**Automated source/build checks: PASS on the referenced main commit.**  
**Hosted authenticated module acceptance: NOT VERIFIED in this audit.**  
**School M-Pesa provider acceptance: NOT VERIFIED.**  
**Business M-Pesa: PARTIALLY IMPLEMENTED; invoice/storefront settlement remains blocked.**  
**Chatify-tracked person-to-person transfer: NOT IMPLEMENTED.**  
**Whole-system production readiness: NOT CERTIFIED.**

This status is deliberate: do not turn untested hosted flows or a user-operated `*334#` handoff into a false “all tests passed” claim.
