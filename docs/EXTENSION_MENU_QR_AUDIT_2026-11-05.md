# Published extension menu and passkey QR audit

Tested the exact published **Kestrel 1.0.1** app on the standard macOS 26 ARM64 runner in [run 42036805210](https://github.com/shay2000/Kestrel-chromium/actions/runs/42036805210), audit source `03beb31621143d6a680cc6bb974355d63a8de926`. The DMG SHA-256 was checked against `15d8a915d80f2d183811040a766ab1265e2e43868280b7154334381ad20cf343`; the copied app passed deep/strict signature verification. No app code, release assets or user profile data were changed by this follow-up.

**Both requested feature gates remain unmet.** Audit execution completed twice, but the workflow's final feature-acceptance step failed. Installation success is separate from toolbar/action support; a native Bluetooth prompt is separate from QR display.

## Extension placement

Installed the actual Google Translate extension through its Store listing and native confirmation. Its signed manifest was present in Kestrel's own profile. Inspected accessibility buttons in the real native toolbar region and opened the macOS **Extensions** menu with physical pointer events.

- The toolbar exposed sidebar, back, forward, reload, bookmark, Assistant and address controls. It exposed **no Google Translate action or Extensions button**.
- The macOS Extensions menu contained **Manage Extensions…** and **Import packages in Kestrel Settings → Extensions**. It contained **no installed extension action**.

This release therefore does not meet the user's extension-bar requirement. `KestrelCommands.swift` builds only a management menu; `BrowserToolbar` does not host extension actions. CefSwift currently selects `CEF_CTT_NONE`, so Chromium's own toolbar/action controls are hidden. This is missing Kestrel action UI, not evidence that an installed extension has a working popup.

A proper implementation must host genuine runtime actions inside Kestrel and test their current-tab context, popup, dismissal, badges/pinning and restart. Listing installed names or opening `default_popup` as an ordinary page is not equivalent to an extension action. Stock CEF exposes its complete Chrome toolbar through `GetChromeToolbar`; it does not expose a standalone extension-action controller. Keeping the custom Kestrel toolbar requires additional engine/UI integration, with visual comparison and native popup acceptance. No placeholder action buttons were added in this audit.

## Native QR display

The disposable localhost fixture requested actual Chromium WebAuthn UI using trusted native button clicks. No virtual authenticator, mocked Bluetooth adapter or fabricated QR was used. Every request was aborted after capture; no phone ceremony or personal account was used.

| Request | Initial native run | After Bluetooth power request |
| --- | --- | --- |
| Sign in using a random credential with hybrid transport | No FIDO QR; Bluetooth gate | No FIDO QR; Bluetooth gate |
| Discoverable sign-in with hybrid hint | No FIDO QR; Bluetooth gate | No FIDO QR; Bluetooth gate |
| Cross-platform registration with hybrid hint | No FIDO QR; Bluetooth gate | No FIDO QR; Bluetooth gate |

All six attempts displayed **“Turn on Bluetooth?”** and **“Bluetooth must be on to use your passkey on a different device.”** The audit pressed the native **Turn on** control. Vision QR detection found **zero `FIDO:/` codes** in the captured native UI.

The runner's actual `system_profiler SPBluetoothDataType -json` report identified an **`APPLE_VIRTUAL`** controller, address **`NULL`**, state **`attrib_off`**. `blueutil --power` returned `0`. A real `blueutil --power 1` request exited **75**, with **“Failed to switch bluetooth power on in 10 seconds”**; power remained `0`. Retrying all three requests after that attempt produced the same native Bluetooth gate.

Chromium 156's [hybrid flow](https://github.com/chromium/chromium/blob/156.0.8078.48/chrome/browser/webauthn/authenticator_request_dialog_controller.cc) calls `EnsureBleAdapterIsPoweredAndContinue` before entering `kCableV2QRCode`. Its off state selects the Bluetooth power sheet. This explains the observed runner limitation; it does **not** establish that Kestrel displays a QR on a physical Mac. QR rendering itself, as well as an actual phone ceremony, remains unverified. The earlier separate virtual FIDO2 test does not satisfy either gate.

[Evidence artifact 13418374821](https://github.com/shay2000/Kestrel-chromium/actions/runs/42036805210/artifacts/13418374821), ZIP SHA-256 `ad05c7796cb1d154b56ee50ab1a26cbd7227dbc87832d7a0f1b6d3717897b2d2`, contains both result files, screenshot/OCR/AX captures, events, Bluetooth metadata and the combined summary. It expires 5 December 2026. The workflow and fixture are retained for repeatable acceptance on hardware that can actually enable Bluetooth.
