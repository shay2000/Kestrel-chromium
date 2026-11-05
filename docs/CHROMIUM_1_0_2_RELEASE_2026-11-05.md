# Chromium 1.0.2 release provenance — 5 November 2026

Published [v1.0.2-chromium-preview.1](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.2-chromium-preview.1), the Apple silicon extension preview.

- Verified app source/tag: `757a17f779ea6dfe01527500c1189e4cebaedc09`.
- Complete native build/acceptance: [run 42085793532](https://github.com/shay2000/Kestrel-chromium/actions/runs/42085793532), job 127450399324.
- Original clean DMG artifact: [13444795070](https://github.com/shay2000/Kestrel-chromium/actions/runs/42085793532/artifacts/13444795070), digest `sha256:4b368265ad2ced2c2c1e8f5129cb7809a8389abf1b00e0749fc5904342153b12`.
- File: `Kestrel-Chromium-1.0.2-arm64.dmg`.
- DMG SHA-256: `2f54d9ea0655af392adb48b6d2221c416a3cc3f2ca95400a22f8c2963f238c47`.
- Publication: [run 42087963304](https://github.com/shay2000/Kestrel-chromium/actions/runs/42087963304).
- Permanent assets: [DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.2-chromium-preview.1/Kestrel-Chromium-1.0.2-arm64.dmg) · [checksum](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.2-chromium-preview.1/Kestrel-Chromium-1.0.2-arm64.dmg.sha256).

The publication job ran ten guard tests, required the successful native workflow/source/artifact to match, verified the downloaded artifact digest and DMG checksum, mounted the original DMG read-only, checked version 1.0.2, arm64, the strict deep signature and removal of CI fixtures, then uploaded and downloaded the release assets and compared their hashes. It did not rebuild the app or replace older releases.

## Native acceptance

The final packaged-app workflow passed the original 17 real pointer/keyboard focus, first-click, address, toolbar/page join, canvas-colour, document controls and refused-connection assertions. Native overlay/window-order regression, seven CRX cases and 11 CEF lifecycle/ownership cases passed. The ownership regression repeats 50 transferred layout arguments and checks final release.

Google Translate and Dark Reader install through their real Store listings and native permission UI. Dark Reader's page styling survives restart. Genuine Google Translate actions open from Kestrel's toolbar/menu/sidebar, report the selected example.com tab, open their options in Kestrel, and respond to both visible Settings sidebar-toggle states. A clean launch without forced renderer accessibility or prior external AX inspection opens the real action for example.org. Quitting with the popup open passes. Window censuses report zero escaped standalone Chromium toolbars and separately record the actual toolbar embedded beneath Kestrel's header.

The original WebKit comparison and native captures were inspected. This is acceptance of the observed presentation and paths, not catalogue-wide, complete tabs/windows API, split/Spaces/tiling or feature-parity certification.

## Remaining limits

Apple silicon, macOS 14+ deployment target, ad-hoc signed and not notarised. Native action acceptance does not establish dynamic shortcut artwork/badge mirroring or visible Settings-import acceptance. Physical phone/QR ceremonies remain unverified: the hosted virtual Bluetooth controller stayed off and no native FIDO QR appeared. Apple's Passwords helper requires an Apple-accepted signed browser identity that Kestrel lacks. The renderer sandbox and framework/helper layout remain enabled; no paid passkey service, credential-store copying, browser-identity spoofing, main merge or WebKit release/update-feed change was added.
