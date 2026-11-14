# Mobile UX error and copy audit — 14 November 2026

## Scope
Reviewed the Flutter client entry point and shared API layer in `mobile/lib/main.dart`, the business and school owner dashboards in `mobile/lib/owner_dashboards.dart`, and their widget tests. The main client file contains the shared request layer and the majority of mobile feature screens, so the fixes centralize behavior there rather than patching individual pages independently.

## Changes
- Added `friendlyErrorMessage` as the shared user-facing error normalizer.
- Network lookup failures, socket/client failures, timeouts, connection resets, TLS handshake failures, and browser network failures now display: **Connect to the internet or Wi-Fi to continue.**
- Authentication, permission, missing-resource, and server failures now display short, actionable messages.
- Technical response details, HTML/JSON parser failures, HTTP diagnostics, and exception names are no longer surfaced to users.
- Replaced direct exception rendering in common snackbars, form feedback, dashboard load states, and account/session error states with the shared normalizer.
- Applied matching connection and generic failure messaging to both owner dashboards.
- Removed verbose owner-dashboard descriptions and security implementation explanations from the visible interface; retained concise labels and payment/security-critical status.
- Shortened encryption key transfer instructions while retaining the minimum passphrase and transfer requirements.
- Kept successful empty results distinct from failed network requests: a genuinely empty account remains an empty state; a failed fetch displays the connection message instead of pretending there are no records.

## Verification added
- Unit tests cover offline/socket errors, timeouts, browser network errors, HTTP 401/403/5xx handling, technical response sanitization, and readable validation messages.
- Widget test covers the school owner dashboard's offline state and verifies that raw SocketException text is not shown.

## Audit notes
- This is a client-side UX/error-handling audit. Server authorization, payment confirmation, encryption, and data access logic were not weakened or changed.
- Automated GitHub Actions results are required before calling the branch verified. Real-device offline/online behavior and visual review still require acceptance testing on a phone.
