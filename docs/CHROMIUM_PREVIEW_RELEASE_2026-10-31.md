# Published Chromium preview — 31 October 2026

At the user's request, published [Kestrel Chromium 1.0.0 — Preview 1](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.0-chromium-preview.1). This is a public **prerelease**, not a stable/notarised release. The original WebKit release and update feed are unchanged. `main` remains unmerged; the release tag names the tested application source directly.

## Downloads

- [Kestrel-Chromium-1.0.0-arm64.dmg](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.1/Kestrel-Chromium-1.0.0-arm64.dmg)
- [SHA-256 sidecar](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.1/Kestrel-Chromium-1.0.0-arm64.dmg.sha256)

Apple silicon only; macOS 14+ deployment target, tested on macOS 26.6.2. The app is ad-hoc signed and not notarised. No Intel binary, Developer ID/Gatekeeper acceptance or signed automatic-update appcast is supplied.

```text
DMG size:   171075044 bytes
DMG SHA256: 94692b366d7ae355d6936b3212506fd5b31249df3da86bf966603b48e3377508
```

With both files downloaded into the same directory:

```sh
shasum -a 256 -c Kestrel-Chromium-1.0.0-arm64.dmg.sha256
```

## Provenance and verification

| Item | Verified value |
| --- | --- |
| Release tag | `v1.0.0-chromium-preview.1` |
| Exact tagged application source | `a3e63faab8e002bfb2c1f618f4f1c0a9390f7ed0` |
| Successful application build/acceptance run | [41208164060](https://github.com/shay2000/Kestrel-chromium/actions/runs/41208164060) |
| Original DMG artifact ID | `13044824637` (`Kestrel-Chromium-macOS-DMG`) |
| Original artifact ZIP SHA256 | `8da735660d7c5649c31290356179b727654ae8fc5a61eaff002a756af6f660cb` |
| Successful publication run | [41210623134](https://github.com/shay2000/Kestrel-chromium/actions/runs/41210623134) |
| Publication workflow/script source | `490fe29a882a3b0deb10a5b64ce208e974788381` |
| Publication evidence | [Artifact 13046430962](https://github.com/shay2000/Kestrel-chromium/actions/runs/41210623134/artifacts/13046430962) |
| Published release/DMG/checksum asset IDs | `429986907` / `695607806` / `695608194` |
| Published at | `2026-10-31T14:33:27Z` |

The publication job used the standard `macos-26` runner on macOS 26.6.2. It checked the original run's successful conclusion, repository/workflow, exact source and artifact ID/digest. It downloaded the existing artifact ZIP, verified its pinned SHA-256, required exactly the DMG and sidecar, and checked the DMG checksum. It did not rebuild or modify the tested application.

`hdiutil verify` passed. The job mounted the DMG read-only, passed strict/deep app signature verification, confirmed version 1.0.0 and arm64, checked the Bluetooth purpose string and absence of the CI extension fixture, then detached it. Both assets were uploaded to a draft and downloaded again using their asset IDs. Their hashes matched the original files before the draft was published as a prerelease. The release metadata and exact tag/source were read back separately. All **nine publication guard tests** passed locally and on the Mac, including failed/wrong-source builds, substituted/expired artifacts, corrupt ZIP/DMG bytes, path/checksum substitution and draft resumption by ID.

The evidence artifact contains `release-verification.json` and read-only `codesign` metadata for Apple's system password helper. That metadata collection did not execute the helper or access credentials. App runtime acceptance remains the [original lifecycle/Web Store/WebKit comparison evidence](CHROMIUM_LIFECYCLE_FIXES_2026-10-31.md); publication verification is not a new physical-authentication test.

## Authentication limits

The chosen free route is Chromium's native phone/QR hybrid transport, conditional on a real physical ceremony. The hosted runner reached Bluetooth setup but did not detect a `FIDO:/` QR or authenticate with a phone; the separate virtual FIDO2 round trip passed. No physical phone/USB/Touch ID/iCloud/provider ceremony is claimed.

[Apple Passwords extension research](APPLE_PASSWORDS_EXTENSION_2026-10-31.md) found a documented macOS 15.5+ native-helper identity restriction. Kestrel is absent from Apple's list and the ad-hoc app has no accepted Team identity. Supported future integration needs Kestrel's own signing identity, Apple's inclusion and a macOS update, followed by actual native-host/credential acceptance. Installing the official extension alone does not establish access, and its verification-code QR feature is separate from WebAuthn.

## Publishing mechanism

The legacy `scripts/publish-public-release.sh` targets the original WebKit download repository and was not used. `.github/workflows/publish-chromium-preview.yml` publishes only from `release/chromium-preview` in `shay2000/Kestrel-chromium`, using the reviewed `.github/releases/chromium-preview.json` request. Pushing changes to its request/workflow/publisher paths on that dedicated branch triggers publication; do this only for an explicitly requested preview release. Existing tags, release metadata and asset bytes must match; conflicting content is refused without overwriting. The workflow can resume an interrupted matching draft. GitHub's runner token is scoped to Actions read and repository contents write; no signing key or personal token is stored in source.
