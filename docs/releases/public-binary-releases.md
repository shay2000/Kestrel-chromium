# Publishing Kestrel Browser binaries

The public `shay2000/Kestrel-Browser` repository is a download page. Keep the implementation repository and all source history private. Create public release tags from a page-only commit in that repository; never push or tag a private source commit there.

`scripts/publish-public-release.sh` builds a universal Release app with Xcode, verifies its nested signatures, creates a Sparkle-signed archive/appcast, and uploads them to a versioned GitHub Release. It targets `main` in the public repository explicitly and refuses to publish unless the public Git tree contains exactly `README.md` and the five approved screenshot PNGs, the repository is public, and the tag does not already exist. The blob-only allow-list rejects source files and every other unexpected path.

The approved public screenshots are `screenshots/new-tab.png`, `screenshots/split-view.png`, `screenshots/assistant-sidebar.png`, `screenshots/assistant.png` and `screenshots/shortcuts.png`. Keep them cropped to the app window and free of account or personal data.

## Preparing an update

1. Update `VERSION` and `MARKETING_VERSION` in both Xcode build configurations. Increase `CURRENT_PROJECT_VERSION` in both configurations above the last published bundle version for every release; Sparkle uses that numeric value to decide whether an update is newer. Version 1 starts at `202610041317` so it can update the earlier 0.1.0 build, whose bundle version was `202610040110`.
2. Run `scripts/publish-public-release.sh` on the Mac that holds the Sparkle Keychain item named **Private key for signing Sparkle updates**, account `kestrel-browser`.
3. The script uploads `Kestrel-Browser.zip` and `appcast.xml`. The app checks `https://github.com/shay2000/Kestrel-Browser/releases/latest/download/appcast.xml` automatically and offers updates through Sparkle. The user can also run **Kestrel → Check for Updates…**.

The EdDSA private key remains in the login Keychain. Never export it to a file or copy it into GitHub Actions, either repository, or a release asset. The corresponding public key is embedded in the app. Keep the public README and release notes free of implementation sources.

The current release is ad-hoc signed and is not notarized because this machine has no Developer ID certificate. Sparkle's archive signatures protect in-app updates; they do not remove Gatekeeper's first-install warning. Use a Developer ID identity and notarize the app before describing a later release as verified/notarized or expecting a seamless first launch.
