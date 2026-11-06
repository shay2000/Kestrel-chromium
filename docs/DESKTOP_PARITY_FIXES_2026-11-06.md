# Desktop parity fixes — 6 November 2026

Follow-up to [the desktop audit](../HANDOFF_DESKTOP_ADVANCED_TEST_LOG_2026-11-05.md). The comparison baseline is the shipped WebKit 1.0.0 app. `main` and the published preview remain unchanged during review.

## Changes under validation

- Address focus: CEF page activation no longer invokes the content-click callback. That callback clears address editing, so calling it when the native address field makes its page key undid the requested focus. Actual content clicks still clear editing and select the pane.
- Split page ownership: each persistent CEF browser has one weakly held SwiftUI host. A new host supersedes its predecessor before the old view is dismantled. Outgoing single-page/split hosts cannot hide the new host's window, remove its toolbar accessibility, or reset its overlay state.
- Split keyboard commands: Kestrel intercepts its configured Command-arrow bindings before Chromium's history accelerators. The native route and menu share the same tab/search placement operation, respect shortcut recording, and apply only to a browser document without a sheet.
- SwiftPM discovery: generated app, CEF and dependency trees are excluded from the root source target, with an explicit default localisation. Retained WebKit-only integration tests are guarded from the Chromium target; portable and shared assistant/settings tests remain included.
- Saved Chats: startup archive counts are being traced using synthetic records, without logging message contents. Runtime diagnosis and verification are recorded below.

## Verification

Initial implementation: `26bff50d5428dd01c302514538e062556267ae35`, [Mac run 42172316244](https://github.com/shay2000/Kestrel-chromium/actions/runs/42172316244).

The packaged Chromium app compiled on macOS. Native overlay regression passed, including activation without clearing address focus. Full suite and visible desktop acceptance are in progress.

This Linux workspace has no Swift toolchain; Python syntax and whitespace checks pass. Native results, captures and any remaining failures will be recorded before completion.

## Authentication limits

The hosted Mac's virtual Bluetooth controller cannot power on. The real hybrid request reaches macOS's Bluetooth setup sheet; synthetic WebAuthn is separate evidence. A physical phone/QR ceremony cannot be accepted from this runner. Apple's iCloud Passwords extension still requires Kestrel's own signed identity to be accepted by Apple's helper. These are external hardware/identity gates, not a reason to alter Chromium's authenticators or impersonate another browser.
