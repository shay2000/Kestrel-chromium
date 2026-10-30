# Browser design and architecture references

## Search

Reference repository: [driceroland/Search](https://github.com/driceroland/Search)

The read-only temporary clone was `main` at commit `491f3214063212fac176a7ad95467f0821040451` (24 September 2026). Its [README screenshot](https://raw.githubusercontent.com/driceroland/Search/main/.github/screenshot.png) and SwiftUI layout informed the restrained tab rail, compact controls, predictable spacing and page-first treatment. The code was inspected as a reference only; nothing from Search was copied into Kestrel.

Ideas that remain useful:

- Keep the dependency-free Swift package openable in Xcode and keep WebKit behind a small native boundary.
- Treat one live web view per tab as an explicit resource-lifecycle decision; Kestrel now preserves each selected tab's page state.
- Keep the browser surface dominant, and use a small consistent palette and spacing scale instead of adding more chrome than a page needs.
- Treat private browsing, history, downloads, site permissions and credentials as separate product decisions with clear storage rules.

Search also contains a custom passkey/WebAuthn relay. It is not a Kestrel reference implementation: Kestrel uses `WKWebView`, Apple's documented Web Authentication path and the browser credential manager for the OS permission state. Do not import custom website JavaScript or bypass the Apple-managed entitlement boundary.

## Comet and BrowserOS

- Comet's installed macOS app was inspected locally on 25 September 2026. The useful interaction pattern is an always-visible, labelled Assistant control that opens a right-side conversation panel with a clear header, mode controls, page context and an anchored composer. This is a local UI observation, not a claim about Comet's current public feature set.
- BrowserOS Neo was inspected locally for a light, quiet browser toolbar and vertical-tab rail. Its public product documentation is at [BrowserOS docs](https://docs.browseros.com/changelog).

Kestrel adapts these patterns with native SwiftUI. Liquid Glass uses Apple's [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) where available (macOS 26 or later), with a native material fallback for the macOS 14 deployment target. This reference does not imply parity with either browser.

## Passkey platform boundary

Apple documents that a `WKWebView` automatically handles web Authentication challenges and directs browser apps to `ASAuthorizationWebBrowserPublicKeyCredentialManager` to check/request permission. General-site browser passkeys still require the Apple-managed capabilities and a matching signed provisioning profile; see [Passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers). Kestrel's approval-only entitlement template remains disabled until Apple grants them.
