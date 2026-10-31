# Extension installation must stay in Kestrel

## Reproduction and cause

The user reported that installing an extension opened what looked like Chrome behind Kestrel. This reproduced on the **published Preview 1 DMG**, with no application-source changes, in [Mac reproduction run 41212287730](https://github.com/shay2000/Kestrel-chromium/actions/runs/41212287730). Window ownership and page-target evidence establish that the extra window belongs to Kestrel's embedded Chromium process/profile; it is not a launch of an installed Google Chrome app or an install into Chrome's personal profile.

- Before installation: no Chromium toolbar and no auxiliary page target.
- After Google Translate: a full **New Tab – Chromium** window, with an address/search bar, native toolbar/tab group and the post-install bubble. Its `chrome://newtab/` target is separate from the Store page.
- After Dark Reader: the same native Chrome window contains its new-tab page and Dark Reader's `https://darkreader.org/help/en/` welcome page. The welcome page is absent from Kestrel's tab collection.
- After restart: the extra toolbar disappears, while Dark Reader still styles Kestrel's page. This explains why the previous install/effect/restart tests passed: they did not reject additional browser windows after each installation.

The matching [Chromium post-install implementation](https://github.com/chromium/chromium/blob/156.0.8078.48/chrome/browser/ui/extensions/extension_install_ui_desktop.cc) calls `FindOrCreateVisibleBrowser` to display its post-install UI. The matching [CEF Chrome host implementation](https://github.com/chromiumembedded/cef/blob/4fa4ab5/libcef/browser/chrome/chrome_browser_host_impl.cc) internally makes Views-hosted browsers popup-style windows, rather than ordinary tabbed Chrome windows. Chromium therefore creates an ordinary browser for that notification. Extension welcome/options APIs can also create tabs in it.

The previous lifecycle patch correctly registered these browsers through CEF's default client so they could close cleanly. It did not hand them to the app's window/tab UI. Extension installation/effects were verified; that was insufficient visual acceptance of the installation experience.

## Implementation

The revision-checked CefSwift patch now reports browsers created through the Chrome default client to Kestrel, excluding explicit DevTools popups. Each app-created page retains its existing Views host, helper layout, Chromium runtime and renderer sandbox.

Kestrel intercepts the auxiliary browser's initial **main-frame** navigation before it loads. Its actual method and default-profile identity are checked. Blank/new-tab post-install destinations are dismissed. A permitted initial GET for an HTTP(S), validated extension-origin or allow-listed Chromium settings page opens in Kestrel's own tab collection, then the provisional native browser closes. Creation/closure is deferred beyond CEF's creation/navigation callbacks. The existing browser registry still owns lifetime and quit draining. Request bodies are not copied, POST is not replayed as GET, and another profile is not forwarded into Kestrel's ordinary profile.

Valid `chrome-extension://<32-character a–p ID>/...` pages retain their extension origin through address normalisation and the browser navigation delegate. They no longer become a web search or get cancelled solely because they are extension pages. Chromium continues to enforce which extensions/resources exist and their origin permissions. Website navigation does not obtain an arbitrary native command or credential bridge.

This handles installation UI and initial welcome/options navigation. It is **not complete virtualisation of `chrome.tabs`/`chrome.windows`**: a provisional native tab ID is not preserved when its initial GET becomes a Kestrel-owned tab. Workflows that depend on that original ID, delayed blank-tab updates, POST-created tabs, other profiles or native extension action popups still require their own compatibility work. Do not infer password-manager or passkey acceptance from this routing.

## Regression checks

The Store harness now records AX windows, native Chromium toolbar controls, visible process-owned windows and page/worker targets before installation, after each extension and after restart. Any escaped Chromium address/search bar fails acceptance. Dark Reader's welcome page must still exist; hiding or destroying every extension-created page would not pass.

A disposable MV3 fixture declares an options page. The harness invokes the extension's actual `chrome.runtime.openOptionsPage()` API, requires its promise to succeed, reads the extension-origin document and repeats the window check. The fixture is removed before distribution. Real Store installations still use their listing buttons and native permission confirmations, followed by live Dark Reader effects, restart and crash-report checks.

Platform-neutral routing coverage checks exact welcome URLs/query/fragment preservation, blank install tabs, extension options, invalid extension origins/ports, unsafe schemes, URL credentials, POST and profile boundaries. Native C-callback tests additionally check default-client notification, explicit DevTools exclusion, main-frame-only interception and callback cleanup after close.

Linux Swift 6.0.3: **419 tests, five skips, zero failures**. The revised patch applies cleanly to the pinned CefSwift revision and a second application is recognised as already applied.

## Verified Mac acceptance

Source/check head **`51fd1003aa7a3be3c3e834487e577b9c6a5b34db`**, [run 41214983097](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097), **macOS 26.6.2 ARM64 / Xcode 26.6 / Swift 6.3.3**: the complete workflow passed. This includes the app build, seven native crypto and seven C-callback/lifetime cases, browser/MV3/selection checks, actual dirty-form close/quit cancellation, both Store installs, extension options, clean restart, WebKit visual comparison, signatures and fixture-free DMG packaging. The final Google Translate/options captures and labelled WebKit comparison were inspected.

| Window census stage | Escaped Chromium toolbar count | Observed page |
| --- | --- | --- |
| Before install | 0 | Kestrel New Tab |
| After Google Translate | 0 | Store page, with its installed extension worker; no native Chrome new-tab target |
| After Dark Reader | 0 | Dark Reader help in Kestrel's sidebar and Store tab |
| Extension options | 0 | Fixture's actual extension-origin document, complete and titled in Kestrel |
| After restart | 0 | example.com, with Dark Reader styling active again |

The options API's promise returned success. The final hosted document reported `ready: complete`, its exact extension-origin URL and fixture text. The test resolves the final target afresh because the provisional native target is intentionally closed; retaining that old socket caused earlier harness failures even though the options page rendered. No tested-process crash report was found. Dark Reader styling passed before and after restart. Native permission confirmation and the default engine identity remained intact; the diagnostic user-agent probe was **false**.

Evidence retained with the successful run:

- [Store/window/options acceptance, artifact 13048375398](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097/artifacts/13048375398): window census JSON, actual pages/workers, screenshots, native prompts, persistence and result.
- [WebKit comparison, artifact 13048000776](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097/artifacts/13048000776): original WebKit 1.0.0 and Chromium on the same page/runner. This is a point comparison, not universal feature parity.
- [Lifecycle evidence, artifact 13048545251](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097/artifacts/13048545251) and [runtime evidence, artifact 13047845976](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097/artifacts/13047845976).
- [Clean DMG, artifact 13048270527](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097/artifacts/13048270527), original artifact ZIP digest `18d85942f9eceb0367fc1a2b3113cf555f7141d88cf42be6d65c712fc95a986d`.

Physical passkey authentication remains unverified. The native runner still reached Bluetooth setup without a detected phone-pairing QR; the separate virtual FIDO2 round trip passed. This extension/window fix does not change that acceptance boundary.
