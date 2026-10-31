# Apple's iCloud Passwords extension in Kestrel

Researched 31 October 2026 against Apple's current documentation, official extension listing and public browser-distribution data. **The official extension is not a working Apple Passwords integration for the current ad-hoc Kestrel preview.** There is a documented route for future support, but using CEF or installing the extension does not satisfy Apple's native-helper restrictions.

## What the extension provides

Apple's [Mac guide](https://support.apple.com/guide/passwords/mchlf7ac261e/mac) directs users to Passwords → Get Browser Extension for supported browsers. The [official Chrome Web Store listing](https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj), offered by Apple Inc., currently lists version **3.4.0**, updated 30 September 2026. It advertises filling/saving iCloud Keychain passwords and generating verification codes on macOS Sonoma or later. Its right-click QR feature configures verification codes; it does not establish WebAuthn passkey support.

Earlier inspection of that official package as data found Manifest V3, a service worker, the `nativeMessaging` permission and `chrome.runtime.connectNative("com.apple.passwordmanager")`. No personal vault was opened and no helper protocol was copied or implemented. Installing the CRX and completing a password/passkey ceremony are separate acceptance checks.

## The concrete blocker

Apple's [own explanation of its browser restrictions](https://github.com/apple/password-manager-resources#how-apple-uses-web-browser-extension-distribution-information) says that, from **macOS 15.5**, its iCloud Passwords native-messaging helper only communicates with known browsers. Apple periodically consumes its public browser-distribution list and signs launch-environment constraints into the helper shipped with macOS. Adding a browser to the repository therefore also requires an **OS update** before the installed helper accepts it.

The [browser-distribution data inspected at commit c7aeff1](https://github.com/apple/password-manager-resources/blob/c7aeff114575f18bd90c64dd4f45ff373abc745b/quirks/web-browser-extension-distribution-information.json) contains browser bundle identifiers, code-signing identifiers, code-signing Team IDs and, for Chromium browsers, extension-install paths. **Kestrel is absent.** The current preview is ad-hoc signed and has no Developer Team identity. Consequently it cannot be treated as an accepted Kestrel identity in Apple's helper. This is a documented compatibility blocker, not a claim that the extension has been installed and failed a live account sign-in.

CEF's Chrome runtime includes extension machinery, but that does not grant Apple's helper permission to launch for Kestrel. Native-host discovery/registration, allowed extension origins and Apple's signed browser-identity constraints are separate checks. The managed browser passkey entitlement is yet another route; it must not be confused with this extension allowlist. Pre-15.5 systems also require explicit native-host and credential-flow acceptance: their absence from the newer restriction does not prove compatibility.

## Supported route to investigate next

1. Establish Kestrel's own durable distribution/signing identity and actual extension-install path. Preserve the Chromium sandbox and Kestrel's separate profile.
2. Ask Apple to include that identity in `apple/password-manager-resources`, using the issue/PR route Apple documents. Researching this option has not submitted anything to Apple, and acceptance/timing are not guaranteed.
3. After Apple ships the identity in an OS update, inspect the actual installed helper's launch constraints and verify native-host discovery for Kestrel. A list entry alone is insufficient.
4. Install the official extension through the native Store confirmation, then accept its actual pairing/unlock UI and password fill/save, verification codes, dismissal and restart with a user-owned disposable test account. Test passkeys separately if claiming them.

Apple documents this read-only metadata command for checking the installed helper; it does not access a password store or execute the helper:

```sh
codesign -d -vvvv /System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper
```

Do not spoof another browser's bundle/team identity, re-sign Apple's helper, alter its launch constraints or copy another browser's credential/profile data. Those are not supported integration work.

## Cost and chosen passkey route

The Apple extension does not require a password-manager subscription, and requesting inclusion through Apple's public repository is not a paid API. However, there is no verified way for this ad-hoc preview to satisfy its signed-identity restriction for free. Normal Developer ID distribution is separate from a free extension download; do not promise that adding a JSON entry makes an ad-hoc app compatible.

The user's accepted direction is Chromium's own **phone/QR hybrid WebAuthn transport**, conditional on actual operation. It avoids direct access to the Mac's Apple Passwords store and needs no paid passkey service. It requires a compatible nearby phone holding the site's passkey, Bluetooth on both devices and network access. The hosted Mac reached the real Bluetooth prompt and **Turn on Bluetooth** dialogue; it did not produce a detected `FIDO:/` QR or complete a phone ceremony. Separate virtual FIDO2 registration/assertion passed. **Physical QR sign-in remains unverified** and is not advertised as working in the preview. See [free passkey options and runner evidence](FREE_PASSKEY_OPTIONS_2026-10-31.md).
