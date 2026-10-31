# Native Chrome Web Store acceptance — 31 October 2026

Kestrel was operated on the standard GitHub macos-26 ARM64 runner (macOS 26.6.2, Xcode 26.6, Swift 6.3.3), using the actual bundled CEF app and its own anonymous profile. The test visits the public store links, clicks the page's **Add to Chrome** button and approves Chromium's visible **Add extension** dialogue. It does not replace `chrome.webstorePrivate`, call an installation API directly or use the local CRX importer.

| Store extension | Native installation observed | Runtime evidence |
| --- | --- | --- |
| [Google Translate](https://chromewebstore.google.com/detail/google-translate/aapbdbdomjkkjkaonfhkkikfgjllcleb), 2.0.18 | Native permission dialogue, added-to-Chromium notice, correct ID and installed manifest | Translation itself was not exercised |
| [Dark Reader](https://chromewebstore.google.com/detail/dark-reader/eimadpbcbfnmbkopoojfekhnkhdbieeh), 4.9.134 | Native permission dialogue, added-to-Chromium notice, correct ID and installed manifest | On example.com: ten Dark Reader style elements, its metadata marker and background `rgb(24, 26, 27)` |

These observations are from [run 41191810296](https://github.com/shay2000/Kestrel-chromium/actions/runs/41191810296), source `4052ab95318c385499382c227b07691b968f0a2f`. The Google Translate permission screenshot was manually inspected. **The overall acceptance failed at restart**: both extension packages remained on disk, but Dark Reader did not activate after relaunch, and a crash report identified the original Kestrel process in `CefRuntime.shutdown()`.

The store's “Switch to Chrome” recommendation banner appeared in the same session that successfully installed both extensions. It is not an installation-capability verdict. An initially narrow viewport placed the enabled install button outside the visible region; the test now scrolls the observed button into view and checks its hit target. Kestrel also retains CEF's real Chromium user-agent identity instead of replacing its product/version with `KestrelChromium/1.0`. The evidence does not establish that this identity change alone was necessary for installation.

## Quit/restart follow-up

The subsequent [source investigation and ordinary-user edge-case map](CHROMIUM_CRASH_REVIEW_2026-10-31.md) ranks the likely causes and proposed fixes. It distinguishes source-confirmed lifecycle gaps from the crash sequence reproduced here.

The first crash stack showed the pinned CefSwift revision synchronously re-entering `NSApp.terminate` from the last registered browser's `OnBeforeClose` callback, reaching `CefRuntime.shutdown()`. A revision-checked experiment deferred that final termination request to the main queue. It built and ran in [run 41192769207](https://github.com/shay2000/Kestrel-chromium/actions/runs/41192769207), source `74ed60ae41d654546075322873406489a81ed8b7`.

**The follow-up failed too.** Both extensions installed again, and Dark Reader produced ten styles and a dark background before restart. Both package manifests remained after restart. However, Dark Reader did not inject its styles afterwards. The original process, PID 5680, crashed with `EXC_BAD_ACCESS`/`SIGSEGV` in CEF shutdown; its stack now reached shutdown from the queued termination closure. The newly launched process was PID 10181. Deferring termination alone did not fix the crash or post-restart activation, so that experiment was removed from the build. The final build retains the pinned upstream CefSwift implementation. The exact cause of the native shutdown failure, and whether it causes the activation failure, remain unresolved.

The [acceptance artefact](https://github.com/shay2000/Kestrel-chromium/actions/runs/41192769207/artifacts/13039762082), named `Kestrel-Chromium-web-store-acceptance`, retains screenshots, OCR/AX captures, JSON events, package manifests and full crash reports until 30 November 2026. The native install prompt and failed-restart screenshots were visually inspected. The workflow is correctly red; package files alone are insufficient for acceptance.

The runner's app build and seven native CRX verification tests passed. The Linux suite also passed: 414 tests, five skips, zero failures. Those results do not override the failed native acceptance. Next work must resolve CEF/browser/profile teardown and establish actual extension activation after startup. A successful rerun requires both stored extension IDs, Dark Reader's live page styles after relaunch and no crash report for a tested process. No passkey result is implied.

## Test scope

`scripts/test-chrome-web-store-macos.swift` is a disposable-runner UI harness. Its loopback-only DevTools connection reads fixed diagnostics and sends real pointer input to observed page buttons; native confirmation uses accessibility or a visible screenshot target. Screenshots, OCR, event records, installed manifests and crash diagnostics are retained as Actions artefacts. Debugging is enabled through runner launch arguments, not the distributed app's configuration.

This checks the named extensions' installation and the described runtime behaviour. It does not establish catalogue-wide API compatibility, Google Translate translation quality, automatic updates, the Settings importer, iCloud Passwords/native messaging or a website passkey ceremony. No account sign-in, credentials, checkout or purchase is used.
