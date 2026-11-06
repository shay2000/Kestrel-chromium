# Passkeys through Chromium without paid services

Researched 31 October 2026. Kestrel uses CEF's Chrome runtime, with Chromium 156.0.8078.48. A browser can support WebAuthn without direct access to the Mac's iCloud passkeys. The credential provider, transport and browser UI must each work; the presence of `navigator.credentials` alone establishes none of them.

## Options

| Route | Payment requirement | Requirements and Kestrel status |
| --- | --- | --- |
| Chromium's phone/QR hybrid transport | No browser entitlement or passkey-service subscription is needed for this transport; uses an existing compatible phone | Phone holds the website's passkey, both devices have working Bluetooth and network access, and the site permits that authenticator. Kestrel's native UI and a real phone ceremony require separate acceptance. |
| Bitwarden browser extension | Its free account includes passkey management and usage | User installs and signs in to the official extension. Bitwarden implements a WebAuthn provider in the browser extension. Its provider flows, injection and restart behaviour must be accepted specifically in Kestrel; two other extensions working does not establish this. |
| KeePassXC plus KeePassXC-Browser | Free/open-source software, no subscription | User-managed desktop database and official browser extension, paired through native messaging, with passkeys enabled. Kestrel's native-host discovery and complete provider ceremony remain unverified. |
| Existing USB FIDO2 security key | No browser entitlement or subscription; buying a key costs money if the user has none | Site and key must support the required discoverable credential/user verification options. Physical USB operation has not been tested on the hosted Mac. |
| Direct iCloud Keychain / system passkey providers on the Mac | No verified route in an ad-hoc build without Apple's managed browser capability | Chromium explicitly checks the browser public-key-credential entitlement. Switching to Chromium does not remove this system requirement. |
| Apple's official iCloud Passwords extension | No extension subscription, but no verified free compatibility route for this ad-hoc app | Apple's macOS 15.5+ helper accepts listed signed browser identities; Kestrel is absent. Inclusion requires Apple's intake and a later OS update, then actual native-host acceptance. Its advertised QR feature concerns verification codes, not phone WebAuthn. See [the Apple extension research](APPLE_PASSWORDS_EXTENSION_2026-10-31.md). |
| Chromium's older local Touch ID authenticator | Not a verified free route for the distributed Kestrel app | Requires appropriate Apple signing and a matching keychain access group; the stock engine also has a build-time group configuration. This is separate from the phone transport. |

The practical native route to pursue first is Chromium's own hybrid exchange with a phone the user already owns. The native browser generates the actual pairing QR code and performs the protocol. Kestrel must not manufacture a decorative QR code, copy credentials from another browser or create a parallel credential store. Bluetooth proves proximity; it is not an optional replacement for network connectivity. A remote hosted runner cannot complete a ceremony with a user's nearby physical phone.

The free extension-provider route is also plausible, particularly for someone already using Bitwarden or KeePassXC. It must remain user-selected and user-managed. This research does not authorise connecting to a personal vault, importing credentials, signing in to an account or changing another application's native-host registration automatically.

## What the pinned Chromium code says

Chromium's [iCloud system implementation](https://github.com/chromium/chromium/blob/156.0.8078.48/device/fido/mac/icloud_keychain_sys.mm#L228) checks `com.apple.developer.web-browser.public-key-credential` in `ProcessHasEntitlement()`, and its availability result uses that check. This is direct evidence that CEF's Chrome runtime cannot simply assume iCloud access in an ad-hoc build. An entitlement added to a plist is not an Apple-granted capability. See [Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).

The pinned [Chrome WebAuthn delegate](https://github.com/chromium/chromium/blob/156.0.8078.48/chrome/browser/webauthn/chrome_web_authentication_delegate.cc#L395) builds the local Touch ID keychain group from the engine's team and bundle identifiers. Chromium's [Touch ID credential-store contract](https://github.com/chromium/chromium/blob/156.0.8078.48/device/fido/mac/credential_store.h) explains that this store uses an entitlement-scoped keychain and real Apple signing. It is not a generic no-signing fallback.

Google documents [cross-device passkey authentication in Chrome](https://developers.google.com/identity/passkeys/supported-environments). That establishes a supported Chrome transport, while Kestrel's packaged CEF build still needs its own acceptance. [FIDO's cross-device troubleshooting guidance](https://www.passkeycentral.org/launch-and-grow/troubleshooting-guidance/cross-device-sign-in) covers common Bluetooth/proximity and QR-scanning failures.

In the [pinned Chrome request delegate](https://github.com/chromium/chromium/blob/156.0.8078.48/chrome/browser/webauthn/chrome_authenticator_request_delegate.cc#L603), hybrid discovery generates a real caBLE pairing string, hands it to the native dialogue controller and configures the network context. This path is separate from the Mac iCloud entitlement check.

[Bitwarden's current pricing/features](https://bitwarden.com/pricing/) lists passkey management and usage among the core features in every account. Its [provider architecture](https://contributing.bitwarden.com/architecture/deep-dives/passkeys/implementations/provider/browser-extension/) describes its browser-extension WebAuthn implementation. [KeePassXC's guide](https://keepassxc.org/docs/KeePassXC_UserGuide#_passkeys) documents browser passkey support, the connected database and extension setting. Those are provider capabilities; Kestrel compatibility remains an additional test.

## Runner probe and its limits

The packaged app now includes a Bluetooth purpose string so macOS can ask for proximity access when Chromium requests it. The renderer sandbox stays enabled. No managed Apple entitlement is fabricated or added.

The disposable runner probe first requests a native hybrid assertion for localhost with a random nonexistent credential, captures the real browser UI, and checks for a `FIDO:/` QR using Vision. It cancels the request without scanning or authenticating. Missing Bluetooth hardware or an OS permission prompt is recorded as a limitation; it must not be reported as a successful physical ceremony.

A separate test adds a disposable CDP virtual FIDO2 authenticator. It creates a credential and asserts it on the local fixture, verifies the assertion's ECDSA signature, origin/challenge binding, relying-party hash, credential identity and user-presence/verification flags, then removes the virtual device. This validates synthetic WebAuthn protocol plumbing. It does not prove that a phone, physical security key, Touch ID, iCloud or a password-manager extension works.

Native and synthetic results are intentionally recorded separately in `lifecycle-acceptance/result.json`. In the expanded passing runner, allowing Bluetooth and choosing Chromium’s Turn on still left the native request at that step; no FIDO QR was detected. The separate synthetic round trip passed. Physical phone, USB, Touch ID, iCloud and extension-provider ceremonies remain unverified. The final source `a3e63faab8e002bfb2c1f618f4f1c0a9390f7ed0` passed [run 41208164060](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060); the [lifecycle record](CHROMIUM_LIFECYCLE_FIXES_2026-10-31.md) retains the screenshots and separate results; no paid service is required or added by this probe.
