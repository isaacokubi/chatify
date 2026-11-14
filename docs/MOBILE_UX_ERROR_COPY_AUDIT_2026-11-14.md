# Mobile UX error and copy audit — 14 November 2026

## Scope
Reviewed the shared Flutter client and API layer in `mobile/lib/main.dart`, the business and school owner dashboards in `mobile/lib/owner_dashboards.dart`, the call flow in `mobile/lib/call_screen.dart`, encryption UI flows, and the related widget/unit tests. The Flutter client is shared across Android, iOS, web and desktop targets, so these UI changes apply across those platforms rather than being Android-only.

## Changes
- Added `friendlyErrorMessage` as the shared user-facing error normalizer.
- Network lookup failures, socket/client failures, timeouts, connection resets, TLS handshake failures, and browser network failures now display: **Connect to the internet or Wi-Fi to continue.**
- Authentication, permission, missing-resource, and server failures now display short, actionable messages.
- Technical response details, HTML/JSON parser failures, HTTP diagnostics, and exception names are no longer surfaced to users.
- Replaced direct exception rendering in common snackbars, form feedback, dashboard load states, and account/session error states with the shared normalizer.
- Applied matching connection and generic failure messaging to both owner dashboards, including HTTP 408/timeouts.
- Prevented failed dashboard requests from also displaying misleading “No school linked” or “No business linked” empty states.
- Sanitized socket call-error feedback and removed redundant workspace/POS helper paragraphs and verbose success copy.
- Removed verbose owner-dashboard descriptions and security implementation explanations from the visible interface; retained concise labels and payment/security-critical status.
- Shortened encryption key transfer instructions while retaining the minimum passphrase and transfer requirements.
- Kept successful empty results distinct from failed network requests: a genuinely empty account remains an empty state; a failed fetch displays the connection message instead of pretending there are no records.

## Verification added
- Unit tests cover offline/socket errors, timeouts, browser network errors, HTTP 401/403/5xx handling, technical response sanitization, and readable validation messages.
- Widget tests cover offline owner-dashboard states and verify that raw SocketException text and false empty states are not shown.
- Additional tests cover HTTP 408 connection messaging.

## Audit notes
- This is a client-side UX/error-handling audit. Server authorization, payment confirmation, encryption, and data access logic were not weakened or changed.
- Essential payment-confirmation and encryption-recovery warnings remain because removing them could mislead users or risk account/data recovery.
- Automated GitHub Actions results are required before calling the branch verified. Real-device offline/online behavior and visual review still require acceptance testing on a phone.
