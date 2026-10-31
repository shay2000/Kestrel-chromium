# Kestrel Chromium

Kestrel Chromium is the Chromium-engine build of the Kestrel macOS browser. It embeds the Chrome-style Chromium runtime through [CEF](https://bitbucket.org/chromiumembedded/cef/) and [CefSwift](https://github.com/Rajaniraiyn/CefSwift); web pages are rendered by Chromium, not `WKWebView`.

The app carries over Kestrel's SwiftUI browser, tabs and split view, assistant and provider integrations, bounded page operator, local profile fill, MCP server, bookmarks, settings, updater, and optional Codex host. Chromium backs each tab and the extension manager. The built-in `chrome://extensions` page uses Chromium's own runtime. Kestrel Settings stages Manifest V3 extension folders, ZIP archives, and signature-verified CRX3 packages for permission review; approved extensions load when Kestrel starts. Compatibility varies by extension and has not been established for the Chrome Web Store catalogue as a whole.

CRX3 imports verify RSA/SHA-256 or ECDSA/P-256 signatures and preserve the signed developer extension ID when Chromium loads the extracted package. Conflicting manifest keys, tampered packages and legacy CRX2 files are rejected. ZIP and folder imports have no verified package signature. This verification does not prove Chrome Web Store provenance or broad API compatibility.

The Chromium build keeps its own browser profile. Cookies and history from a WebKit build are not migrated. Assistant and app settings continue to use Kestrel's existing local settings and Keychain stores.

On first launch, Kestrel seeds YouTube, Gmail, Google Drive, X, Reddit, and OneDrive into both the bookmarks and the pinned site tiles above the tab list. Existing bookmark lists and pinned sites, including deliberately empty lists, are kept as they are.

## Download the preview

[Download the Apple silicon DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.2/Kestrel-Chromium-1.0.0-arm64.dmg) · [SHA-256 checksum](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.2/Kestrel-Chromium-1.0.0-arm64.dmg.sha256) · [Release notes](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.0-chromium-preview.2)

Chromium Preview 2 fixes the full Chromium window that appeared after extension installation: Google Translate stays in Kestrel, and welcome/options pages open as Kestrel tabs. The build is ad-hoc signed and **not notarised**, targets macOS 14+, and was tested on macOS 26.6.2 ARM64. macOS may block its first launch. The release contains the exact verified DMG, with uploaded bytes downloaded again and checksum-checked; see [release provenance](docs/CHROMIUM_PREVIEW_2_RELEASE_2026-10-31.md). Physical phone/QR passkey sign-in remains unverified. Apple's official iCloud Passwords extension also needs Apple's accepted signed browser identity; Kestrel is absent from its current list. See [the Apple extension research](docs/APPLE_PASSWORDS_EXTENSION_2026-10-31.md).

## Port status

The full app builds and launches on a standard GitHub macOS 26 ARM64 runner with Xcode 26.6. [Run 41214983097](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097), source `51fd1003aa7a3be3c3e834487e577b9c6a5b34db`, passed native CRX and lifecycle regressions, browser/MV3/selection smoke, real tab/quit cancellation with an unsaved background form, rapid/last-page closure, both Web Store installs with zero escaped Chromium toolbar windows, actual extension options, restart, the original WebKit 1.0.0 comparison and clean DMG packaging. See [extension-window acceptance](docs/EXTENSION_WINDOW_OWNERSHIP_2026-10-31.md). Screenshots and logs are retained with the run.

Native Chrome Web Store installation and restart have passed with Google Translate and Dark Reader through Chromium’s permission dialogue. The current [run 41214983097](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097) also checks each installed window, Dark Reader's welcome page and an actual fixture options API/document. Dark Reader changed example.com before and after relaunch, with no tested-process crash report. Initial GET routing does not preserve provisional native tab IDs; complete tabs/windows API compatibility remains unimplemented. See [current window acceptance](docs/EXTENSION_WINDOW_OWNERSHIP_2026-10-31.md), [the original store record](docs/CHROME_WEB_STORE_ACCEPTANCE_2026-10-31.md) and [lifecycle acceptance](docs/CHROMIUM_LIFECYCLE_FIXES_2026-10-31.md). The store’s “Switch to Chrome” banner is not an installation verdict. Catalogue-wide compatibility, native action popups and the Settings importer remain unverified. Physical passkey sign-in remains unverified; [free passkey research](docs/FREE_PASSKEY_OPTIONS_2026-10-31.md) distinguishes phone/QR, extension providers and Apple's managed iCloud route.

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
