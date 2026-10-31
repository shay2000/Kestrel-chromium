# Kestrel Chromium

Kestrel Chromium is the Chromium-engine build of the Kestrel macOS browser. It embeds the Chrome-style Chromium runtime through [CEF](https://bitbucket.org/chromiumembedded/cef/) and [CefSwift](https://github.com/Rajaniraiyn/CefSwift); web pages are rendered by Chromium, not `WKWebView`.

The app carries over Kestrel's SwiftUI browser, tabs and split view, assistant and provider integrations, bounded page operator, local profile fill, MCP server, bookmarks, settings, updater, and optional Codex host. Chromium backs each tab and the extension manager. The built-in `chrome://extensions` page uses Chromium's own runtime. Kestrel Settings stages Manifest V3 extension folders, ZIP archives, and CRX packages for permission review; approved extensions load when Kestrel starts. Compatibility varies by extension and has not been established for the Chrome Web Store catalogue as a whole.

The Chromium build keeps its own browser profile. Cookies and history from a WebKit build are not migrated. Assistant and app settings continue to use Kestrel's existing local settings and Keychain stores.

On first launch, Kestrel seeds YouTube, Gmail, Google Drive, X, Reddit, and OneDrive into both the bookmarks and the pinned site tiles above the tab list. Existing bookmark lists and pinned sites, including deliberately empty lists, are kept as they are.

## Port status

The full app builds and launches on a GitHub hosted macOS 26 ARM64 runner with Xcode 26.6. [Run 41163450380](https://github.com/shay2000/Kestrel-chromium/actions/runs/41163450380) passed the app build, first-run bookmark/pin screenshot, `example.com` navigation, drag text selection, Chrome Web Store listing, and a same-run launch of the original WebKit 1.0.0 app on that page. A Manifest V3 smoke extension also ran its content script, service-worker message and storage round-trip. The run contains the Mac app archive, a side-by-side WebKit comparison, and runner screenshots.

The Web Store listing displays “Switch to Chrome to install extensions and themes” in Kestrel, so its direct install button is unavailable. The MV3 smoke proves only basic extension execution; a representative catalogue, the importer UI, and Chrome Web Store installation have not passed runtime acceptance. Website passkey registration and sign-in also remain unverified; see [PASSKEY_SUPPORT.md](PASSKEY_SUPPORT.md). The workflow now assembles a versioned Apple Silicon DMG for review, but it is ad-hoc signed and not notarized for public distribution.

One material difference remains in page automation: CefSwift exposes JavaScript execution in the page's main world. Kestrel's CEF operator keeps its fixed scripts, bounded data, action allow-list, approvals, and revalidation, but does not retain WebKit's isolated JavaScript world. Do not treat that as equivalent isolation or use model-supplied JavaScript/selectors.

## Build on macOS

Requirements: macOS 14 or later, Xcode 16 or later, Swift 6, and an internet connection for the pinned CEF package and binary download.

```sh
./build.sh
open build/Kestrel.app
```

Use `./build.sh debug` for a debug configuration. CEF's helper processes use Chromium's sandbox. The generated app is ad-hoc signed for local development; it is not notarized for distribution.

The `macos-26` GitHub Actions workflow builds pull requests and can be run manually. It reports the runner's macOS/Xcode versions, launches and smoke-checks the app, runs the WebKit comparison, then uploads a clean zipped app, a versioned `.dmg` with SHA-256 checksum, screenshots, and the build log. The DMG is an ad-hoc signed review build, not a notarized public release.

## CEF dependency and licensing

The package pins [CefSwift](https://github.com/Rajaniraiyn/CefSwift) at commit `b18cceef8afaf6686147e19a9239f31c2dd81541`, which pins the CEF and Chromium build used by this app. `build.sh` creates the required CEF framework and helper-app layout, embeds Sparkle for the updater, adds Kestrel's macOS browser permission descriptions and URL handling, and packages the CEF, CefSwift and Sparkle notices in `Kestrel.app/Contents/Resources`. A Codex runtime is included only when a developer explicitly supplies the pinned official executable with `KESTREL_CODEX_EXECUTABLE`.

## Source layout

- `KestrelChromium/` — CEF-backed app entry point, browser stores, operator, extension host, and Chromium bridge.
- `KestrelWebKit/` — shared Kestrel UI and engine-independent assistant/settings code, plus retained WebKit reference implementations.
- `Package.swift` — builds the `Kestrel` CEF app product and platform-neutral package tests.
- `build.sh` — bundles the CEF product as a runnable macOS app.
- `.github/workflows/macos-chromium-build.yml` — hosted macOS app build and artifact upload.
