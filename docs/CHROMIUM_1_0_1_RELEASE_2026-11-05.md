# Chromium 1.0.1 release verification

Published [v1.0.1-chromium-preview.1](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.1-chromium-preview.1) on 5 November 2026. It fixes native page/document focus, first-click toolbar actions, address entry, the toolbar/page join, document window controls, HTML canvas colours and an ordinary-network-error crash. Google Translate and Dark Reader installation/options/restart passed inside Kestrel. [Implementation and native acceptance](NATIVE_WINDOW_INTEGRATION_2026-11-04.md).

- [Download the Apple silicon DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.1-chromium-preview.1/Kestrel-Chromium-1.0.1-arm64.dmg)
- [SHA-256 sidecar](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.1-chromium-preview.1/Kestrel-Chromium-1.0.1-arm64.dmg.sha256)

The app reports **1.0.1**, distinguishing it from both previous 1.0.0 previews. Apple silicon only, macOS 14+ deployment target, tested on macOS 26.6.2 ARM64 / Xcode 26.6 / Swift 6.3.3. **Ad-hoc signed and not notarised.** No Intel binary, Developer ID/Gatekeeper acceptance or signed automatic-update appcast is supplied.

```text
DMG size:   171484349 bytes
DMG SHA256: 15d8a915d80f2d183811040a766ab1265e2e43868280b7154334381ad20cf343
```

```sh
shasum -a 256 -c Kestrel-Chromium-1.0.1-arm64.dmg.sha256
```

| Provenance | Verified value |
| --- | --- |
| Exact application source/tag target | `f263131f4617eebcecdbda37c8e1987801ec9e87` |
| Successful build and full native acceptance | [42012454676](https://github.com/shay2000/Kestrel-chromium/actions/runs/42012454676) |
| Original clean DMG artifact | `13407608436`, `Kestrel-Chromium-macOS-DMG` |
| Original artifact ZIP SHA256 | `661bd16fc4a1c8f00bc94985b0ff7a71e5f7bad0806a59232a8c14c1db6025fd` |
| Successful publication run | [42014269895](https://github.com/shay2000/Kestrel-chromium/actions/runs/42014269895) |
| Publication request/workflow source | `9e40124edd2b9b1d25e246ce352eb2032fcbbcb4` |
| Release / DMG / checksum asset IDs | `435080258` / `713067734` / `713068259` |
| Publication time | `2026-11-05T10:53:17Z` |
| Checksum-file SHA256 | `8c85aecfeb1ccb4fafbf9f238170572bf761c289db60b345d907f8274c9dfe67` |

Publication promoted the original clean bytes without rebuilding. It verified the successful workflow/source, exact artifact ID/digest, strict ZIP members and DMG sidecar. `hdiutil verify`, a read-only mount, deep/strict signature verification, app version 1.0.1 and arm64 checks, Bluetooth purpose-string presence and CI-fixture absence passed. Both uploaded draft assets were downloaded by asset ID and hash-compared before publication. The public release, asset sizes/digests and exact source tag were read back. All **10 publication guard tests** passed locally and on the Mac.

The app run passed **17 real macOS focus/toolbar/network assertions**, the native overlay dispatch/ownership regression, **seven CRX tests** and **nine CEF lifecycle regressions**. Browser/MV3/selection smoke, real unsaved-form close/quit cancellation, rapid/last-page closure, both Store install/options/restart journeys, original WebKit comparison and clean packaging passed. All five window-census stages reported zero extra Chromium toolbars. Inspected focus, Store, options and comparison captures. Linux: **426 tests, five skips, zero failures**. The comparison covers the observed basic toolbar/sidebar/page presentation; complete split/Spaces/tiling and feature parity remain outside that acceptance.

[Publication evidence artifact 13409205148](https://github.com/shay2000/Kestrel-chromium/actions/runs/42014269895/artifacts/13409205148) retains the verification JSON and read-only Apple helper metadata until 5 December 2026. The release assets are permanent.

This is native Swift/AppKit/SwiftUI embedding CEF's Chrome runtime, with CEF's original content view, renderer hierarchy and sandbox retained. It is not a maintained Chromium source fork. Initial welcome/options GET routing does not preserve provisional native tab IDs or implement complete tabs/windows APIs. Native extension action popups, the Settings importer and catalogue-wide compatibility remain unverified. Physical phone/QR and credential-provider ceremonies remain unverified; Apple's Passwords helper still requires an accepted signed Kestrel identity. No paid passkey service, credential/profile copy, managed-entitlement spoofing, main merge or original WebKit release/update-feed change is included.
