# Kestrel Chromium

Kestrel Chromium is the Chromium-engine build of the Kestrel macOS browser. It embeds the Chrome-style Chromium runtime through [CEF](https://bitbucket.org/chromiumembedded/cef/) and [CefSwift](https://github.com/Rajaniraiyn/CefSwift); web pages are rendered by Chromium, not `WKWebView`.

The app carries over Kestrel's SwiftUI browser, tabs and split view, assistant and provider integrations, bounded page operator, local profile fill, MCP server, bookmarks, settings, updater, and optional Codex host. Chromium backs each tab and the extension manager. The built-in `chrome://extensions` page uses Chromium's own runtime. Kestrel Settings can review and import Manifest V3 extension folders, ZIP archives, and CRX packages; approved extensions load when Kestrel starts.

The Chromium build keeps its own browser profile. Cookies and history from a WebKit build are not migrated. Assistant and app settings continue to use Kestrel's existing local settings and Keychain stores.

On first launch, Kestrel seeds YouTube, Gmail, Google Drive, X, Reddit, and OneDrive into both the bookmarks and the pinned site tiles above the tab list. Existing bookmark lists and pinned sites, including deliberately empty lists, are kept as they are.

## Port status

The full app builds and launches on a GitHub hosted macOS 26 ARM64 runner with Xcode 26.6. [Run 41159095104](https://github.com/shay2000/Kestrel-chromium/actions/runs/41159095104) passed the app build/archive, fresh launch, screenshot text checks for all six first-run bookmarks, rendered `example.com`, and opened the Google Translate listing on the Chrome Web Store. Its artifacts include the app archive and runner screenshots.

The Web Store listing displays “Switch to Chrome to install extensions and themes” in Kestrel, so direct Chrome Web Store installation is not supported by this CEF build. The listing itself renders. Kestrel's separate extension importer is implemented for reviewed Manifest V3 CRX, ZIP, and unpacked packages; its runtime install flow still needs a dedicated acceptance check. Website passkeys remain unverified in the ad-hoc build and depend on Apple's managed browser capabilities; see [PASSKEY_SUPPORT.md](PASSKEY_SUPPORT.md). The build is not notarized for distribution.

One material difference remains in page automation: CefSwift exposes JavaScript execution in the page's main world. Kestrel's CEF operator keeps its fixed scripts, bounded data, action allow-list, approvals, and revalidation, but does not retain WebKit's isolated JavaScript world. Do not treat that as equivalent isolation or use model-supplied JavaScript/selectors.

## Build on macOS

Requirements: macOS 14 or later, Xcode 16 or later, Swift 6, and an internet connection for the pinned CEF package and binary download.

```sh
./build.sh
open build/Kestrel.app
```

Use `./build.sh debug` for a debug configuration. CEF's helper processes use Chromium's sandbox. The generated app is ad-hoc signed for local development; it is not notarized for distribution.

The `macos-26` GitHub Actions workflow builds pull requests and can be run manually. It reports the runner's macOS/Xcode versions and uploads a zipped `Kestrel.app` artifact plus the build log. It compiles and packages the app; it does not launch the app or claim browser acceptance.

## CEF dependency and licensing

The package pins [CefSwift](https://github.com/Rajaniraiyn/CefSwift) at commit `b18cceef8afaf6686147e19a9239f31c2dd81541`, which pins the CEF and Chromium build used by this app. `build.sh` creates the required CEF framework and helper-app layout, embeds Sparkle for the updater, adds Kestrel's macOS browser permission descriptions and URL handling, and packages the CEF, CefSwift and Sparkle notices in `Kestrel.app/Contents/Resources`. A Codex runtime is included only when a developer explicitly supplies the pinned official executable with `KESTREL_CODEX_EXECUTABLE`.

## Source layout

- `KestrelChromium/` — CEF-backed app entry point, browser stores, operator, extension host, and Chromium bridge.
- `KestrelWebKit/` — shared Kestrel UI and engine-independent assistant/settings code, plus retained WebKit reference implementations.
- `Package.swift` — builds the `Kestrel` CEF app product and platform-neutral package tests.
- `build.sh` — bundles the CEF product as a runnable macOS app.
- `.github/workflows/macos-chromium-build.yml` — hosted macOS app build and artifact upload.
