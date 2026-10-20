# Chatify offline/reconnection validation

Run this checklist on a physical Android device with the PR build installed. CI tests cannot substitute for the airplane-mode test.

## Setup
- Sign in while online and open at least one conversation.
- Wait for messages, contacts, memories, school data, and the relevant business workspace to finish loading once.
- Note the latest message and current saved records.
- Keep a second signed-in account/device available to confirm server-side message delivery and deduplication.

## Startup and cached reads
- [ ] Force-stop Chatify while online, enable airplane mode, and relaunch.
- [ ] Confirm the cached signed-in account opens without a fatal startup screen.
- [ ] Reopen a previously loaded conversation and verify cached messages remain readable.
- [ ] Reopen previously loaded contacts, memories, school, and business views. Cached reads may be stale; the UI must not present them as freshly synced.

## Outgoing text messages
- [ ] While airplane mode is enabled, send a text message in an already-open conversation.
- [ ] Confirm it appears as **Waiting to send • saved on device**, not Delivered or Read.
- [ ] Force-stop and relaunch in airplane mode; confirm the pending message is still present.
- [ ] Restore connectivity while keeping the conversation open. Wait for automatic sync.
- [ ] Confirm the pending marker clears only after the server responds successfully.
- [ ] Confirm the recipient receives exactly one copy.
- [ ] Repeat by briefly disconnecting during a send response, then reconnecting. Confirm the stable client ID prevents duplicate server messages.

## Other features and external services
- [ ] Contacts, memories, school, and business: attempt each supported write while offline. Until that specific action has a durable queue, it must report that it was not synced and must not pretend it was saved remotely.
- [ ] Media: offline upload must clearly report that the attachment was not queued; reconnect and retry only after checking the conversation for a possible prior server result.
- [ ] Notifications: verify the UI never claims a push notification was delivered while the device/server was offline.
- [ ] Payments: do not retry an initiation automatically after a timeout. Check the payment's server status before attempting again; only a verified provider callback may mark a payment successful.

## Acceptance
- [ ] No crash or fatal startup error in airplane mode.
- [ ] Pending text survives restart and is sent exactly once after reconnect.
- [ ] No offline write is displayed as server-confirmed before acknowledgement.
- [ ] No payment or media operation is falsely reported as successful.
- [ ] Record device model, Android version, commit SHA, and any failed steps before approving the offline release.

**Important:** This checklist is a test plan, not evidence that the physical-device test has already been run.