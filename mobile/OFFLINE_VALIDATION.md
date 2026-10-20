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
- [ ] Restore connectivity with the conversation open and confirm automatic sync.
- [ ] Repeat with the conversation closed; wait for the app-wide outbox retry or resume Chatify to trigger sync.
- [ ] Confirm the pending marker clears only after the server responds successfully and the server copy replaces the local copy.
- [ ] Confirm the recipient receives exactly one copy.
- [ ] Repeat by briefly disconnecting during a send response, then reconnecting. Confirm the stable client ID prevents duplicate server messages.

## Other features and external services
- [ ] Contacts and Memory Cards: try each add/save action offline. These actions are not currently queued; the UI must show failure and must not claim a remote save. After reconnecting, retry manually and confirm only one contact/card exists.
- [ ] School: try a non-payment write offline. It must show failure/not synced; do not repeat fee/payment initiation blindly. After reconnecting, verify the server record before retrying.
- [ ] Business offline-create queue: create a supported customer, catalogue item, or task while offline; confirm the queue count increases. Force-stop/relaunch offline and confirm the queued create and conflict count are restored. Reconnect or resume the app, wait for sync, and confirm one server record exists. Repeat after interrupting the sync response. Confirm conflicts/rejections remain visible for review instead of being silently discarded.
- [ ] Business writes outside the supported offline-create queue must report failure when offline; they must not be presented as saved remotely.
- [ ] Media: offline upload must clearly report that the attachment was not queued; reconnect and retry only after checking the conversation for a possible prior server result.
- [ ] Notifications: verify the UI never claims a push notification was delivered while the device/server was offline. Check token-registration failure separately from message-delivery status.
- [ ] Payments: do not retry an initiation automatically after a timeout. Refresh/check the payment's server status before attempting again; only a verified provider callback may mark a payment successful. Confirm offline/timeout states never show a confirmed receipt.

## Acceptance
- [ ] No crash or fatal startup error in airplane mode.
- [ ] Pending text survives restart and is sent exactly once after reconnect.
- [ ] No offline write is displayed as server-confirmed before acknowledgement.
- [ ] No payment or media operation is falsely reported as successful.
- [ ] Record device model, Android version, commit SHA, and any failed steps before approving the offline release.

**Important:** This checklist is a test plan, not evidence that the physical-device test has already been run.