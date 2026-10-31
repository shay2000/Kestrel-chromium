# Apple Passwords and passkey support

Checked 30 September 2026 on macOS 27.0 (26A428), Xcode 27.0 (27A266a).

## Chromium port status — 31 October 2026

The Chromium product uses CEF and does not use `WKWebView` for page content. Its native handoff observes WebAuthn completion or failure and can offer to reopen the page in the default browser; that observer is not a passkey authenticator. Website passkey registration and sign-in with a physical authenticator remain unverified, so complete passkey support is not a release claim. Apple’s AuthenticationServices route for arbitrary relying-party identifiers requires the managed browser capability. Chromium’s other physical authenticator paths still need acceptance; the separate synthetic protocol result is recorded below. Apple approval is separate from Chrome Web Store installation.

Native Chrome Web Store installation and restart have passed for Google Translate and Dark Reader through Chromium’s own permission dialogues after the lifecycle fix. Dark Reader changed a real page before and after relaunch. See [the store acceptance record](docs/CHROME_WEB_STORE_ACCEPTANCE_2026-10-31.md) and [current lifecycle verification](docs/CHROMIUM_LIFECYCLE_FIXES_2026-10-31.md). The “Switch to Chrome” recommendation banner is not an installation verdict. iCloud Passwords/native messaging and actual passkey ceremonies are not established by those extension tests.

The [free Chromium passkey research](docs/FREE_PASSKEY_OPTIONS_2026-10-31.md) identifies the engine’s phone/QR transport and free Bitwarden/KeePassXC extension-provider options separately from native iCloud access. The ad-hoc runner build reached the real Bluetooth permission and Chromium’s **Turn on Bluetooth** passkey dialogue. A separate disposable virtual FIDO2 test verified registration, assertion, signature and origin/challenge/RP binding. These observations do not establish a physical phone, USB key, Touch ID, iCloud or password-manager ceremony. No paid service, managed entitlement or credential-store copy was introduced.

The remainder of this document describes the legacy WebKit route and the Apple approval steps that would be needed for the browser entitlement.

## Legacy WebKit target

Keep authentication in `WKWebView`. Apple documents automatic Web Authentication handling there. Kestrel already uses the default website data store and gates its Settings permission request on both signed browser capabilities. [Apple: passkey use in web browsers](https://developer.apple.com/documentation/authenticationservices/passkey-use-in-web-browsers).

For arbitrary websites, the browser passkey entitlement permits registration and assertion for any relying-party identifier. Apple's current application process requires the **Account Holder of an organisation's Apple Developer account**, browser HTTP/HTTPS handling and a URL/search/bookmark interface. Apple must approve the request and add the managed capability; an entitlement plist alone does not grant it. [Apple: browser passkey entitlement and application requirements](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).

Next owner actions:

1. Apply through [Apple's macOS Browsers Passkeys form](https://developer.apple.com/contact/request/macos-browsers-passkeys/).
2. Obtain approval and a provisioning profile carrying the required capabilities. Only then configure the existing approval-only entitlement template and sign with that profile.
3. Read the entitlements back from the built app; request access from Kestrel Settings.
4. Test website passkey creation, assertion, dismissal and nearby-device sign-in. Verify ordinary Password AutoFill separately. A build, permission state or availability probe is not an end-to-end sign-in.

A `webcredentials` associated domain can support an app's own or cooperating website, but cannot give Kestrel access to every website. [Apple: supporting passkeys](https://developer.apple.com/documentation/authenticationservices/supporting-passkeys).

## Would the iCloud Passwords extension work?

Apple offers an extension route from Passwords → Get Browser Extension for supported third-party browsers. Its official Chromium extension advertises password filling/saving and verification codes on macOS Sonoma and later. The advertised QR feature sets up verification codes; it is not a claim of WebAuthn phone-passkey support. [Apple's Mac guide](https://support.apple.com/guide/passwords/mchlf7ac261e/mac), [Apple's official extension listing](https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj).

Inspection of Apple's official extension package **3.4.0**, downloaded from Google's extension update service for the listing above, confirmed a Manifest V3 service worker and the `nativeMessaging` permission. Its background worker calls `chrome.runtime.connectNative("com.apple.passwordmanager")`. It also requests privacy, declarative-content, navigation, storage, context-menu and scripting APIs, plus access to website origins. The package was inspected as data only: it was not installed, executed or connected to the credential helper. The CRX remains outside Git.

Kestrel's CEF host accepts folder, ZIP and CRX packages after permission review, but the runtime path has not been accepted through the Settings UI. Native-messaging hosts, extension-created UI and broader runtime permission flows have not been accepted in Kestrel. The local CRX3 importer now verifies signatures and preserves the signed extension identity. Native store installation uses Chromium’s own installer. Neither result establishes Apple’s credential-helper compatibility. Kestrel has no verified integration with Apple's credential helper; unpacking the CRX does not establish that connection. No undocumented helper protocol or password-store bridge was added. The legacy WebKit route exposes separate native-messaging integration points. [Apple: extension-controller delegate](https://developer.apple.com/documentation/webkit/wkwebextensioncontrollerdelegate).

A native regression does verify that a simple, explicitly permitted fixture extension still injects its content script into two independent Kestrel tab controllers. That proves the PK-001 isolation change preserves basic extension injection; it does not prove iCloud Passwords compatibility.

## Nearby-device QR sign-in

Apple's supported flow offers **Other Options → Passkey from nearby device** and a QR code, with Bluetooth enabled on the Mac and nearby device. It is an OS/browser WebAuthn exchange, not a URL that Kestrel can encode independently. [Apple: signing in with a passkey](https://support.apple.com/guide/passwords/mchl4af65d1a/mac).

The current ad-hoc build lacks both managed browser capabilities. A local assertion-only fixture produced `NotAllowedError` and no observed QR sheet in the signed QA app. Some attempts were explicitly rejected because the document was not focused under background UI automation; another returned the generic platform/context rejection. **This is inconclusive about all hybrid-authenticator configurations, and does not establish working QR support or prove that QR is universally impossible without the capabilities.** No account credential was created, submitted or inspected. The test was stopped without a phone scan or successful assertion.

Repeat manually with the final signed app in the foreground:

```bash
python3 -m http.server 18764 --bind 127.0.0.1 --directory scripts/fixtures
```

Open `http://localhost:18764/passkey-compatibility.html`, then try the standard and hybrid buttons. The fixture requests a localhost assertion with random challenge/credential identifiers and discards any result. It performs no registration. The focus flag helps separate an automation-focus failure from a capability failure. Cancel the sheet after checking its options; the random credential cannot prove a real account sign-in. Repeat a real website ceremony with a user-owned test account separately. The two labelled fallback-fixture buttons exercise only the app's banner; they do not authenticate.

## Available fallback and limits

File → Open Page in Default Browser remains an explicit fallback. Failed launch keeps the notice and allows retry; selecting Kestrel as the default cannot create a handoff loop. The fallback browser needs its own Apple Passwords/passkey support. It has separate cookies, so completing sign-in there does **not** sign Kestrel in. No credentials or sessions are copied back.

The [bug handoff](archive/development/BUG_FIX_HANDOFF.md) tracks this external capability gate as **PK-002**. It remains open after the crash and reliability repairs.
