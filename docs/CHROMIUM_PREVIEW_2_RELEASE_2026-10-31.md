# Chromium Preview 2 release verification

Published [v1.0.0-chromium-preview.2](https://github.com/shay2000/Kestrel-chromium/releases/tag/v1.0.0-chromium-preview.2) on 31 October 2026, replacing Preview 1 as the recommended download. It fixes the extra full Chromium window after extension installation. [Root cause and Mac acceptance](EXTENSION_WINDOW_OWNERSHIP_2026-10-31.md).

- [Download the DMG](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.2/Kestrel-Chromium-1.0.0-arm64.dmg)
- [SHA-256 sidecar](https://github.com/shay2000/Kestrel-chromium/releases/download/v1.0.0-chromium-preview.2/Kestrel-Chromium-1.0.0-arm64.dmg.sha256)

Apple silicon only, macOS 14+ deployment target, tested on macOS 26.6.2 ARM64. Ad-hoc signed and not notarised; no Intel binary, Developer ID/Gatekeeper acceptance or signed update appcast is supplied. Both previews use application version 1.0.0; replace the old app with the new download, identified by its release tag and checksum.

```text
DMG size:   171122820 bytes
DMG SHA256: 4b6b3f95d9c23b63ad67d1cc62855fccefe73078ee49ebb21d19baeb877ab8fe
```

```sh
shasum -a 256 -c Kestrel-Chromium-1.0.0-arm64.dmg.sha256
```

| Provenance | Verified value |
| --- | --- |
| Exact source/tag target | `51fd1003aa7a3be3c3e834487e577b9c6a5b34db` |
| Successful build and full native acceptance | [41214983097](https://github.com/shay2000/Kestrel-chromium/actions/runs/41214983097) |
| Original clean DMG artifact | `13048270527`, `Kestrel-Chromium-macOS-DMG` |
| Original artifact ZIP SHA256 | `18d85942f9eceb0367fc1a2b3113cf555f7141d88cf42be6d65c712fc95a986d` |
| Successful publication run | [41215849512](https://github.com/shay2000/Kestrel-chromium/actions/runs/41215849512) |
| Publication request/workflow source | `640e1ec0eb9f90340cb543a6390ac19fa4f4bd59` |
| Release / DMG / checksum asset IDs | `430023534` / `695763427` / `695763701` |
| Publication time | `2026-10-31T15:39:45Z` |

The publication job promoted the original clean bytes without rebuilding. It verified the successful run, exact source, workflow, artifact ID/digest, ZIP contents and DMG sidecar. `hdiutil verify`, a read-only mount, strict/deep signature verification, app version/arm64 checks, Bluetooth purpose-string presence and CI-fixture absence all passed. Both draft assets were downloaded by asset ID and compared with the original hashes before the draft became a public prerelease. The published release metadata, asset sizes/digests and exact source tag were read back. All nine publication guard tests passed locally and on the Mac.

The full app run separately passed seven native crypto and seven C-callback/lifecycle cases, both actual Store installations, zero escaped Chrome toolbar windows, Dark Reader's welcome page/live styling and restart, actual fixture options API/document, cancellation/quit smoke and original WebKit comparison. Linux: 419 tests, five skips, zero failures. Screenshots were inspected; see the linked acceptance record for scope and artifacts.

[Publication evidence artifact 13048116612](https://github.com/shay2000/Kestrel-chromium/actions/runs/41215849512/artifacts/13048116612) retains the verification JSON and read-only Apple helper metadata.

Initial welcome/options GET routing does not preserve provisional Chrome tab IDs or implement complete tabs/windows API virtualisation. Native extension action popups, delayed blank-tab updates, other profiles and POST-created tabs need separate work. Physical phone/QR, iCloud and password-manager ceremonies remain unverified. Preview 2 does not change Apple's helper identity restrictions, merge `main`, modify the original WebKit release or copy credential/profile data.
