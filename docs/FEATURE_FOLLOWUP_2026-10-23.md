# Feature follow-up verification — 2026-10-23

This records the follow-up changes made on `recovery/merge-school-improvements-20261023` after the reconciliation audit. It is based on the current local checkout; it does not claim device, production, or live-provider acceptance.

## Changes

- **Memories:** card actions now appear in a wrapped footer below each memory's content. Delete uses a confirmation dialog; complete/restore and conversation navigation remain available.
- **Sparks:** the newest active item from the current user is rendered as the content inside the single “Your Spark” circle. Opening a Spark launches a full-screen sequential viewer with progress, tap navigation, pause/resume, expiry-aware API data, text and image support, video playback controls, retry handling, and reduced-motion handling. The raw media URL is not rendered as text. Video playback retains the authorized URL privately in the controller; autoplay remains subject to platform policy. Glitter accents animate only while the viewer is present and follow the reduced-motion preference.
- **Presence:** the server tracks authenticated socket IDs per user. Only the final socket disconnect updates `lastSeen` and broadcasts offline, and a reconnect during persistence suppresses a stale offline event. Existing `privacy.lastSeen` filtering remains on API profile responses and offline timestamp payloads. Presence events contain user IDs/status only, not tokens. Fan-out is bounded to the latest 100 conversations.
- **Mentions:** typing `@` filters already loaded conversation members and displays selectable suggestions; IDs are stored in message metadata and names are emphasized in the client rendering. Existing server validation restricts IDs to current conversation members. Mention notification preference is applied independently of ordinary message notification preference; notification payloads continue to omit message plaintext. E2EE ciphertext handling is unchanged.

## Verification run

Commands run from the repository directories:

| Command | Result |
| --- | --- |
| `cd server && npm test` | Exit 0; 211 passed, 0 failed. Includes presence tracker and mention notification unit tests. |
| `cd server && npm run lint` | Exit 0; configured JavaScript syntax checks passed. |
| `cd mobile && flutter test --concurrency=1` | Exit 0; 30 passed, 0 failed. Includes owner Spark circle and memory action placement widget assertions. |
| `cd mobile && flutter analyze --no-fatal-infos` | Exit 0; 24 informational diagnostics, no warning/error diagnostics. |
| `cd mobile && dart format lib/main.dart test/widget_test.dart` | Exit 0; no files changed by final formatting pass. |
| `git diff --check` | Exit 0. |

The first backend test invocation in the restricted shell could not bind its API integration test to loopback; it was rerun with the permitted elevated execution and the complete suite passed. No production credentials were used and no live payments were initiated.

## Remaining acceptance limits

- Presence unit tests exercise multiple sockets, duplicate disconnect, reconnect, and stale socket removal, but no multi-device deployed Socket.IO test or end-to-end privacy API test was run in this follow-up.
- Mention suggestions and member-ID validation are implemented, but device keyboard/touch acceptance, encrypted-client interoperability across old versions, notification delivery through Firebase, and duplicate delivery under production reconnects remain to be tested. Mention IDs are outside ciphertext metadata; the message text remains encrypted and is not sent to notification payloads.
- Spark widget coverage verifies the current user's content appears in its own circle. Native device autoplay, offline cached Spark media, storage expiry, and narrow-device full-screen gestures were not exercised on hardware. Images require a currently authorized/available media URL unless already provided as a local data image. Attachments are not claimed to be durable offline.
- No startup or send-latency benchmark was run, so this follow-up makes no quantitative performance claim.
- No schema migration is required: existing `lastSeen`, `privacy.lastSeen`, Spark, and mention fields are reused.
- Daraja sandbox, publicly reachable callback, deployed database, and real-device offline acceptance remain external gates.
