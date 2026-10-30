# Kestrel Chromium

This repository is a Chromium-based macOS build of Kestrel. Its `Kestrel` app target embeds the Chromium Embedded Framework through [CefSwift](https://github.com/Rajaniraiyn/CefSwift); it does not use `WKWebView` to render pages.

The current CEF app is an early port with a SwiftUI tab strip, address/search bar, page navigation, pop-up-to-tab routing, and Chromium DevTools. The original WebKit source is retained in `KestrelWebKit/` while Kestrel's assistant, page operator, extension manager, passkey handoff, and related features are ported. The Chromium app does not yet read or migrate WebKit profile data.

## Build on macOS

Requirements: macOS 14 or later, Xcode 16 or later, Swift 6, and an internet connection for the pinned CEF package and binary download.

```sh
./build.sh
open build/Kestrel.app
```

Use `./build.sh debug` for a debug configuration. CEF's helper processes use Chromium's sandbox. The generated app is ad-hoc signed for local development; it is not notarized for distribution.

The repository includes a `macos-26` GitHub Actions workflow. Each build uploads a zipped `Kestrel.app` artifact. The workflow compiles and packages the app; it does not run browser acceptance tests.

## CEF dependency and licensing

The package pins [CefSwift](https://github.com/Rajaniraiyn/CefSwift) at commit `b18cceef8afaf6686147e19a9239f31c2dd81541`, which pins the CEF and Chromium build used by this app. `build.sh` creates the required framework and helper-app layout, then packages the CEF and CefSwift notices in `Kestrel.app/Contents/Resources`.

## Source layout

- `KestrelChromium/` — CEF-backed SwiftUI app.
- `KestrelWebKit/` — original WebKit app source, retained for comparison and platform-neutral tests.
- `Package.swift` — builds the `Kestrel` CEF app product and the original `KestrelWebKit` product.
- `build.sh` — bundles the CEF product as a runnable macOS app.
- `.github/workflows/macos-chromium-build.yml` — hosted macOS app build and artifact upload.
