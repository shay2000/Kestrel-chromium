# Native extension actions in Kestrel

The 1.0.2 source is under native acceptance. The published 1.0.1 DMG has not yet changed.

Kestrel retains Chromium's real Chrome toolbar/action controllers inside its existing CEF page window, behind the original SwiftUI header. Its toolbar button, Extensions command menu and optional sidebar shortcuts activate those controllers through public in-process `NSAccessibilityProtocol` objects. No second browser, remote debugging endpoint, system Accessibility grant or navigation to a `default_popup` URL is used by the product. Renderer web areas are excluded from control discovery. Action requests revalidate the selected tab, browser instance, address and request generation after asynchronous menu dismissal.

Settings → Extensions independently controls the macOS command menu, toolbar and shortcuts beside Chats. Sidebar selection persists by Chromium extension ID; legacy settings retain their original menu/import choices. Chromium's pin controls determine toolbar shortcuts. The catalogue reads bounded metadata only from Kestrel's own default profile and approved import directories. Chromium continues to own permission review, installation, site access and action execution.

CEF retains its original native window classes, content views and renderer ownership. The page keeps a 40-point header reservation. Accessibility children are refreshed from the live CEF root instead of keeping an early empty window snapshot. Chromium may relayout its internal toolbar, so native popup positioning uses the existing transient AppKit window and does not depend on overriding that toolbar's layout. It preserves popup size, delegates and lifetime, clamps placement to the owner's screen and stops tracking on dismissal or a context change. A small reviewed CefSwift wrapper reads Chromium's localised UI strings through public CEF resource APIs.

## Evidence so far

- [Mac probe 42060608797](https://github.com/shay2000/Kestrel-chromium/actions/runs/42060608797), source `01ad464`, installed the real Google Translate extension from its Store page, physically clicked Kestrel's toolbar button, opened the genuine native action and inspected its real popup. `chrome.runtime.id` was `aapbdbdomjkkjkaonfhkkikfgjllcleb`; `chrome.tabs.query({active:true,currentWindow:true})` returned the selected Kestrel `https://example.com/` tab. The popup was visibly rendered inside Kestrel. The renderer viewport remained below the reserved header.
- A later placement probe confirmed the actual pin control and the selected sidebar icon, but failed the mirrored toolbar pin check. Chromium reset its internal toolbar bounds during layout. The current implementation removes that dependency; its complete pin/setup/restart acceptance is pending.
- Linux: 433 tests, five platform skips, zero failures. This includes legacy placement decoding, independent placement/selection persistence, profile-path containment, disabled entries and runtime-localised action names. Linux does not validate the Mac UI.

The final build must pass genuine native pinning, sidebar and menu activation, its extension options page, a fresh launch without forced renderer accessibility, the existing no-extra-Chromium-window census and the full native focus/toolbar regression. No 1.0.2 release is claimed until those checks pass.

## Limits

Packaged icons identify shortcuts; dynamic icon artwork and badge mirroring are not established. Compatibility remains bounded to tested extensions and API paths. In particular, Chromium's programmatic `chrome.action.openPopup` checks its browser window feature flags separately from an actual user action; full catalogue-wide Chrome product compatibility is not claimed. Existing initial GET routing does not preserve provisional Chrome tab IDs or virtualise every tabs/windows API.

This work does not change the passkey result. The hosted Mac's virtual Bluetooth controller did not reach a native FIDO QR. Physical phone/QR ceremonies remain unverified, and Apple's Passwords helper still requires Apple's browser identity acceptance. See the existing authentication records.
