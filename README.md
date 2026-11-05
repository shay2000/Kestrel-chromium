# Kestrel Chromium

Kestrel Chromium is the Chromium-engine build of the Kestrel macOS browser. It embeds the Chrome-style Chromium runtime through [CEF](https://bitbucket.org/chromiumembedded/cef/) and [CefSwift](https://github.com/Rajaniraiyn/CefSwift); web pages are rendered by Chromium, not `WKWebView`.

The app carries over Kestrel's SwiftUI browser, tabs and split view, assistant and provider integrations, bounded page operator, local profile fill, MCP server, bookmarks, settings, updater, and optional Codex host. Chromium backs each tab and the extension manager. The built-in `chrome://extensions` page uses Chromium's own runtime. Kestrel Settings stages Manifest V3 extension folders, ZIP archives, and signature-verified CRX3 packages for permission review; approved extensions load when Kestrel starts. Compatibility varies by extension and has not been established for the Chrome Web Store catalogue as a whole.

CRX3 imports verify RSA/SHA-256 or ECDSA/P-256 signatures and preserve the signed developer extension ID when Chromium loads the extracted package. Conflicting manifest keys, tampered packages and legacy CRX2 files are rejected. ZIP and folder imports have no verified package signature. This verification does not prove Chrome Web Store provenance or broad API compatibility.

The Chromium build keeps its own browser profile. Cookies and history from a WebKit build are not migrated. Assistant and app settings continue to use Kestrel's existing local settings and Keychain stores.

On first launch, Kestrel seeds YouTube, Gmail, Google Drive, X, Reddit, and OneDrive into both the bookmarks and the pinned site tiles above the tab list. Existing bookmark lists and pinned sites, including deliberately empty lists, are kept as they are.

## Download the preview

[Download the Apple silicon DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.1-chromium-preview.1/Kestrel-Chromium-1.0.1-arm64.dmg) · [SHA-256 checksum](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.1-chromium-preview.1/Kestrel-Chromium-1.0.1-arm64.dmg.sha256) · [Release notes](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.1-chromium-preview.1)

The **1.0.1 native window integration preview** fixes the dimmed Kestrel frame, consumed toolbar clicks, address entry, and the separately rounded toolbar/page join. Toolbar dragging and window controls operate the whole document. Page canvas colours now match the original WebKit presentation, including a transparent body over a coloured HTML root. Google Translate and Dark Reader install in Kestrel; eligible initial welcome/options pages open as Kestrel tabs.

Apple silicon only, **ad-hoc signed and not notarised**, macOS 14+ target and macOS 26.6.2 acceptance. The app reports **1.0.1**, distinguishing it from both earlier 1.0.0 previews. [Release provenance](docs/CHROMIUM_1_0_1_RELEASE_2026-11-05.md) records the verified original DMG and downloaded asset hashes. Physical phone/QR passkey sign-in remains unverified. Apple's official iCloud Passwords extension requires an accepted signed browser identity; Kestrel is absent from its current list. See [the Apple extension research](docs/APPLE_PASSWORDS_EXTENSION_2026-10-31.md).

## Port status

The full app builds and launches on the standard GitHub `macos-26` ARM64 runner. [Run 42012454676](https://github.com/shay2000/Kestrel-chromium/actions/runs/42012454676), source `f263131f4617eebcecdbda37c8e1987801ec9e87`, passed all **17 real macOS focus/toolbar/network assertions**, the native overlay dispatch/ownership regression, **seven CRX tests** and **nine CEF lifecycle tests**. Browser/MV3/selection smoke, unsaved-form close/quit cancellation, rapid/last-page closure, both Store installs/options/restart, the original WebKit comparison, signatures and clean DMG packaging passed. Screenshots were inspected. See [native window integration and evidence](docs/NATIVE_WINDOW_INTEGRATION_2026-11-04.md).

The native Store tests use physical mouse events and Chromium's permission dialogue. All five window-census stages reported **zero extra Chromium toolbars**. Dark Reader modified example.com before and after restart; the options fixture's actual API/document loaded in Kestrel. Initial GET routing does not preserve provisional native tab IDs or implement complete tabs/windows APIs. Native action popups, catalogue-wide compatibility and the Settings importer remain unverified. Physical passkey sign-in also remains unverified; [free passkey research](docs/FREE_PASSKEY_OPTIONS_2026-10-31.md) distinguishes phone/QR, extension providers and Apple's managed iCloud route.

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
