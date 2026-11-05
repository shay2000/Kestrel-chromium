# Kestrel Chromium

Kestrel Chromium is the Chromium-engine build of the Kestrel macOS browser. It embeds the Chrome-style Chromium runtime through [CEF](https://bitbucket.org/chromiumembedded/cef/) and [CefSwift](https://github.com/Rajaniraiyn/CefSwift); web pages are rendered by Chromium, not `WKWebView`.

The app carries over Kestrel's SwiftUI browser, tabs and split view, assistant and provider integrations, bounded page operator, local profile fill, MCP server, bookmarks, settings, updater, and optional Codex host. Chromium backs each tab and the extension manager. The built-in `chrome://extensions` page uses Chromium's own runtime. Kestrel Settings stages Manifest V3 extension folders, ZIP archives, and signature-verified CRX3 packages for permission review; approved extensions load when Kestrel starts. Compatibility varies by extension and has not been established for the Chrome Web Store catalogue as a whole.

CRX3 imports verify RSA/SHA-256 or ECDSA/P-256 signatures and preserve the signed developer extension ID when Chromium loads the extracted package. Conflicting manifest keys, tampered packages and legacy CRX2 files are rejected. ZIP and folder imports have no verified package signature. This verification does not prove Chrome Web Store provenance or broad API compatibility.

The Chromium build keeps its own browser profile. Cookies and history from a WebKit build are not migrated. Assistant and app settings continue to use Kestrel's existing local settings and Keychain stores.

On first launch, Kestrel seeds YouTube, Gmail, Google Drive, X, Reddit, and OneDrive into both the bookmarks and the pinned site tiles above the tab list. Existing bookmark lists and pinned sites, including deliberately empty lists, are kept as they are.

## Download the preview

[Download the Apple silicon DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.2-chromium-preview.1/Kestrel-Chromium-1.0.2-arm64.dmg) · [SHA-256 checksum](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.2-chromium-preview.1/Kestrel-Chromium-1.0.2-arm64.dmg.sha256) · [Release notes](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.2-chromium-preview.1)

The **1.0.2 extension preview** adds genuine installed actions to Kestrel's Extensions menu, pinned toolbar shortcuts and optional shortcuts beside Chats. Choose placement and individual sidebar shortcuts in **Settings → Extensions**. Popups stay attached to Kestrel; eligible initial setup/options pages open as Kestrel tabs. Native toolbar attachment now works on new tabs and clean restarts, view ownership survives repeated layout/shutdown, and Settings stays above browser pages.

The release retains the unified document focus, first-click/address controls and toolbar/page join, with the observed WebKit canvas presentation. Apple silicon, macOS 14+ deployment target, **ad-hoc signed and not notarised**. [Release provenance](docs/CHROMIUM_1_0_2_RELEASE_2026-11-05.md) records the tested DMG and uploaded-asset hashes.

## Port status

[Native Mac run 42085793532](https://github.com/shay2000/Kestrel-chromium/actions/runs/42085793532), source `757a17f779ea6dfe01527500c1189e4cebaedc09`, passed all 17 real focus/toolbar/network assertions, native overlay/window-order checks, seven CRX cases, 11 CEF lifecycle/ownership cases, browser/MV3/selection smoke, cancellable/rapid/last-page closure, Store installs/options/restart, genuine extension action/setup/restart/popup-quit acceptance, WebKit comparison and clean DMG/signatures. Screenshots were inspected. [Publication 42087963304](https://github.com/shay2000/Kestrel-chromium/actions/runs/42087963304) verifies and promotes those bytes without rebuilding.

Google Translate's actual popup reported the selected Kestrel URL before and after restart; menu and sidebar actions and both visible placement-toggle states passed. Dark Reader modifies example.com before and after relaunch. Window censuses reject escaped standalone Chromium toolbars while recording the native toolbar embedded beneath Kestrel's own header. [Implementation and evidence](docs/EXTENSION_ACTIONS_2026-11-05.md).

Compatibility remains bounded to tested extensions and API paths. Initial GET routing does not preserve provisional native tab IDs or virtualise every tabs/windows API. Dynamic shortcut artwork/badge mirroring, catalogue-wide compatibility and the Settings importer remain unverified.

Physical phone/QR passkey sign-in remains unverified. The [1.0.1 QR audit](docs/EXTENSION_MENU_QR_AUDIT_2026-11-05.md) produced no FIDO QR because the runner's virtual Bluetooth controller could not power on. Apple's iCloud Passwords helper requires an accepted signed browser identity; Kestrel is absent from Apple's current list. [Free passkey options](docs/FREE_PASSKEY_OPTIONS_2026-10-31.md) · [Apple extension research](docs/APPLE_PASSWORDS_EXTENSION_2026-10-31.md).

One material difference remains in page automation: CefSwift exposes JavaScript execution in the page's main world. Kestrel's CEF operator keeps its fixed scripts, bounded data, action allow-list, approvals, and revalidation, but does not retain WebKit's isolated JavaScript world. Do not treat that as equivalent isolation or use model-supplied JavaScript/selectors.

See [HANDOFF.md](HANDOFF.md) for the active review branch, latest CRX verification results and remaining release gates.

## Build on macOS

Requirements: macOS 14 or later, Xcode 16 or later, Swift 6, and an internet connection for the pinned CEF package and binary download.

```sh
./build.sh
open build/Kestrel.app
```

Use `./build.sh debug` for a debug configuration. CEF's helper processes use Chromium's sandbox. The generated app is ad-hoc signed for local development; it is not notarized for distribution.

The `macos-26` GitHub Actions workflow builds pull requests and can be run manually. It reports the runner's macOS/Xcode versions, launches and smoke-checks the app, runs the WebKit comparison, then uploads a clean zipped app, a versioned `.dmg` with SHA-256 checksum, screenshots, and the build log. The DMG is an ad-hoc signed review build, not a notarized public release.

## CEF dependency and licensing

The package pins [CefSwift](https://github.com/Rajaniraiyn/CefSwift) at commit `b18cceef8afaf6686147e19a9239f31c2dd81541`, which pins the CEF and Chromium build used by this app. `build.sh` resolves that dependency and applies `patches/cefswift-browser-lifecycle.patch`, rejecting an unexpected revision or patch state. It then creates the required CEF framework and helper-app layout, embeds Sparkle for the updater, adds Kestrel's macOS browser permission descriptions and URL handling, and packages the CEF, CefSwift and Sparkle notices in `Kestrel.app/Contents/Resources`. A Codex runtime is included only when a developer explicitly supplies the pinned official executable with `KESTREL_CODEX_EXECUTABLE`.

## Source layout

- `KestrelChromium/` — CEF-backed app entry point, browser stores, operator, extension host, and Chromium bridge.
- `KestrelWebKit/` — shared Kestrel UI and engine-independent assistant/settings code, plus retained WebKit reference implementations.
- `Package.swift` — builds the `Kestrel` CEF app product and platform-neutral package tests.
- `build.sh` — bundles the CEF product as a runnable macOS app.
- `.github/workflows/macos-chromium-build.yml` — hosted macOS app build and artifact upload.
