# Test areas

Run `swift test` on Linux for the platform-neutral suite. The retained WebKit integration tests below target the original engine and have not been ported to the CEF app's APIs; a full macOS `swift test` is not current Chromium acceptance.

For native CRX verification on macOS, run `bash scripts/test-crx-package.sh`. It compiles the production `CRXPackage.swift` with its XCTest cases, using Xcode's CryptoKit/Security implementations and ephemeral signing keys. This suite checks cryptographic package/identity validation, not the Settings file picker, permission review UI or an imported extension running after restart. The Chromium build workflow runs it and uploads its log separately from browser smoke evidence.

The following coverage descriptions and live-test flags are retained for the original WebKit implementation:

- Chat lifetime and routing: `AssistantRoutingRegressionTests` and `TabModelTests`.
- Real WebKit lifecycle, reparenting, passkey watcher, target revalidation and navigation: `WebKitBugRegressionTests`.
- Bounded operator loops/cancellation: `OperatorReliabilityTests`.
- Provider protocol parsing and model-loading generations: provider/catalogue suites.
- Optional network, model/runtime, Keychain and authenticated CLI acceptance is explicitly opt-in; skipped cases are not verified features. Check the individual test's environment guard before enabling it. Do not run authenticated tests with real page text or credentials in fixtures.

Keep synthetic fixtures in test code; keep manual tools in `scripts/` only where they provide coverage not already in the suite. Standalone navigation/passkey/host probes were superseded by native XCTest cases and removed. Build output belongs in a scratch directory, not among test sources.

The macOS workflow accepts `stress_cycles` (1–30) on manual dispatch. This drives both actual Xcode and standalone apps through repeated visible-user interactions, with accessibility/state assertions and synthetic local pages/files. It hides the SwiftPM build output before launch, records per-cycle host memory, and uploads diagnostics and screenshots on failure. `probe_only=true` runs a cached one-cycle diagnostic and does not count as acceptance. A green workflow still requires screenshot review; obscured captures or missing image marks fail visual acceptance. This is UI/packaging stress; live model/helper and retailer acceptance remain separate. See [the Greptile findings and stress scope](../docs/GREPTILE_REVIEW_2026-10-30.md).

## WorkBuddy live acceptance

`WorkBuddyProviderTests` checks fixed tool-free CLI arguments, trusted instruction separation, final-result parsing, old-settings migration and secret-free catalogue loading. Set `KESTREL_WORKBUDDY_LIVE_TEST=1` to additionally exercise the installed CLI and real example.com → IANA navigation in WebKit.

Set `KESTREL_WORKBUDDY_SHOPPING_TEST=1` for the opt-in Apple UK comparison, Demoblaze guest-basket creation/replacement and Magento variant journeys. These use a fresh non-persistent WebKit store, approve only bounded test actions and block checkout. They do not validate the packaged helper/XPC connection. Network/model variability can fail acceptance; report those failures separately from the default suite. The Magento site returned Cloudflare 526 during this pass, so its variant journey remains externally blocked. Never bypass certificate errors to make this gate pass.

Actual packaged-sidebar acceptance and known failures are recorded separately in [WORKBUDDY_SIDEBAR_ACCEPTANCE.md](../docs/WORKBUDDY_SIDEBAR_ACCEPTANCE.md). Build 202610111400 passed the signed helper connection and real sidebar navigation; Apple radio-control configuration/basket failed. The default regression suite does not prove these manual journeys.
