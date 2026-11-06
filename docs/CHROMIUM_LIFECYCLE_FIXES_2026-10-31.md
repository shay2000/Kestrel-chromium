# Chromium lifecycle fixes and Mac acceptance

This implements the ordinary-user cases in [the crash review](CHROMIUM_CRASH_REVIEW_2026-10-31.md). The engine remains the pinned CEF/Chromium build with its sandbox enabled. The reviewed CefSwift changes are applied by `scripts/apply-cefswift-patches.sh` to exactly `b18cceef8afaf6686147e19a9239f31c2dd81541`; an unexpected dependency revision or patch state fails the build. The CEF binary, framework layout and helper packaging are unchanged.

## Changes

| Reviewed case | Implementation |
| --- | --- |
| Native Chrome windows missing from shutdown | Implemented CEF's default client, adopted auxiliary browser IDs in `OnAfterCreated`, and included every registered browser in quit. |
| Popup callbacks affect their opener | Routed title, URL, loading, permission, download and close callbacks by the callback's actual browser ID. Shared-client auxiliary windows receive separate wrappers. Duplicate close completion is ignored. |
| New browser races with quit | Root Chrome browser creation is tracked until adoption or failure. App creation and popup admission stop during quit; late native arrivals close through CEF. A closed pending browser cannot be adopted later, and window destruction retires pending creation. |
| **Stay** loses a tab/form | Tab close retains the model/delegate and its native browser until confirmed window destruction. Cancelling close removes the pending close operation and preserves the form. Pinned-page reset follows the same path. Before an unload choice, background forms are selected; parked windows use a visible presentation host. Background permission requests with no visible presentation window dismiss. Existing pages can reattach during quit while creation remains blocked. |
| Cancelled quit later completes unexpectedly | Unload cancellation clears quit state and invalidates queued finalisation through a generation check. Browser hosts can resume after cancellation. |
| Dialogue/pump reentrancy | JavaScript and site-permission prompts use asynchronous native sheets. Shutdown waits for outstanding prompt callbacks and an inactive message-pump work slice. It runs once after all tracked browsers, pending root creations and owned Chrome windows have drained. |
| Tab churn retains stale ownership | Model/browser mappings validate the weak model identity and detach explicitly. Matching-browser guards protect replacement mappings. The CEF client's initial handler refs now belong to a separate lifetime owner, breaking a per-client retention cycle. |
| Extensions fail after restart | Clean native teardown is required; the store test retains ID/package and live Dark Reader checks after relaunch, plus tested-process crash detection. |

Quit iterates a snapshot of the registry because callbacks can remove entries. No timeout silently forces unsaved pages closed. Lifetime diagnostics contain IDs/counts rather than page contents or credentials, and are enabled only for the disposable runner/debug launch.

## Visual parity

The shared SwiftUI sidebar, pins, toolbar, page cards, typography and Assistant layout are retained. The Mac workflow launches WebKit 1.0.0 on example.com and produces a labelled side-by-side capture. Its small preview is also available in the runner log for inspection. The fixture marker belongs only to the test app and is removed before distribution packaging.

The comparison exposed a Chromium webpage scrollbar that the WebKit host hides. Chromium's `hide-scrollbars` setting now hides web-content scrollbars without changing Kestrel's SwiftUI controls or system preferences. Incoming external URLs prefer the existing browser window, avoiding overlapping windows that share the same tab store.

A loading overlay could remain after navigation because its parent page view observed only the tab metadata, while the toolbar observed the actual browser store. The page now observes that store too, so loading/failure/handoff changes rebuild the overlay. Detaching a SwiftUI host also removes its own native hosting overlay from the longer-lived CEF root, preventing stale spinners or interactive banners across tab changes.

This is visual acceptance of the captured page and browser chrome, not a claim of complete feature parity, every Settings state, animation or authentication surface.

## Regression checks

The five native `KestrelLifecycleTests` exercise the production C callback structs with owned test browser pointers. They verify that a shared-client popup changes its own title and closes its own ID, that the default client registers an auxiliary browser, that duplicate close completes once, that a closed pending creation cannot later attach, and that releasing the CEF client releases its Swift owner/handler graph. They need no loaded CEF framework and run in addition to actual app acceptance.

The UI harness uses a disposable localhost form with real sticky user activation. It chooses **Stay** after the actual Close Tab and app-quit requests and checks the same draft. It also exercises rapid native target closure, closing the final page after a cancelled quit, and opening a URL immediately before quitting. Target close is sent over the browser websocket and requires actual target disappearance, since closing a page destroys that page's connection before its reply may arrive.

Native phone/QR and synthetic FIDO2 tests are separate. The native phase captures the real Bluetooth permission and Chrome UI; the synthetic phase verifies a local assertion signature and its origin, challenge, RP hash, credential identity and UV/UP flags. See [the free passkey research](FREE_PASSKEY_OPTIONS_2026-10-31.md). A synthetic authenticator never counts as a real phone or iCloud ceremony.

## Recorded results

The original failing store-install/quit/relaunch sequence passed in [run 41204037020](https://github.com/shay2000/Kestrel-chromium/actions/runs/41204037020), source `4d3eddad8929245956601e88536088beac91fba6`, on macOS 26.6.2 ARM64 / Xcode 26.6 / Swift 6.3.3. Both real store installs passed. Dark Reader injected ten styles and changed example.com's background before and after restart. No crash report was found for the tested processes. The full workflow passed, including native tests, browser/selection smoke, WebKit comparison, signing and clean DMG packaging.

The complete final source `a3e63faab8e002bfb2c1f618f4f1c0a9390f7ed0` passed [run 41208164060](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060) on the same Mac/Xcode toolchain. **The entire workflow passed.** Seven native crypto cases and five lifecycle cases passed. The actual packaged app preserved the same draft after Close Tab → Stay and quit → Stay with that form in a background tab. Five independent rapid tab closes preserved the original page; closing its last page after cancelled quit kept the app running. Opening a URL immediately before quit/relaunch passed, with no crash report for a tested process. Both native store installs and Dark Reader’s live page operation before/after restart passed again, without user-agent emulation.

The final WebKit/Chromium comparison was visually inspected: shared chrome is preserved, the webpage scrollbar is hidden and the stale loading spinner is gone. The test-only MV3 marker is the expected extra page decoration. This verifies the captured page/chrome, not every UI state.

The native passkey probe granted the runner’s Bluetooth request and selected Chromium’s Turn on, but the request stayed at that Bluetooth step and no FIDO QR was found. Physical phone authentication remains unverified. The separate synthetic WebAuthn registration/assertion passed all signature and binding checks. These are deliberately separate results.

Retained until 30 November 2026: [native lifecycle logs](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13044809732), [screenshots and UI evidence](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13045228729), [store acceptance](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13045188992), [WebKit comparison](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13045795805), [clean app](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13045910032) and [review DMG/checksum](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060/artifacts/13044824637). The final delivery after this source changes documentation only and skips redundant CI.

A screenshot-helper compile error and a page-websocket close acknowledgement error were corrected in the harness during development. The final test creates independent tabs through Kestrel’s actual New Tab control and checks their IDs before closing them. A transient hosted-display capture failure receives at most two retries; every successful assertion still requires a real capture.

Linux Swift 6.0.3: 414 tests, five skips, zero failures. This checks the platform-neutral code and does not establish Mac lifecycle behaviour.
