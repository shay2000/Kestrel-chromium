# Kestrel application artwork

The two SVGs in this folder are the canonical, approved artwork traced from the
user-supplied reference and smoothed with fitted Bézier curves. Preserve their
silhouette, colours, padding and crisp, unblurred bird contours.

- `kestrel-app-icon-basic.svg`: white kestrel on purple; the bundled Finder icon.
- `kestrel-app-icon-dark.svg`: lavender kestrel on charcoal; used in the running
  app's Dock and About panel when Kestrel resolves to dark appearance.

Kestrel's existing System / Light / Dark setting controls the running icon.
System mode follows macOS even when all browser windows are closed. Finder and
the app bundle retain the purple icon. This uses AppKit's
[`applicationIconImage`](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)
and explicit About-panel artwork, supporting the macOS 14 deployment target.

## Regeneration

On macOS, install Pillow and `resvg-py==0.5.0` in a development Python environment,
then run `python3 scripts/generate-app-icons.py` from the repository root.
Normal SwiftPM and Xcode builds use the committed generated resources and need
no Python dependencies.

The script supersamples the SVGs and generates all 16–1024 pixel app-icon sizes,
the two runtime image sets, and `KestrelWebKit/Kestrel.icns`. Every ICNS
representation was decoded and compared with its Xcode image: alpha coverage and
opaque colours match, including the transparent rounded corners.

The retired assets and original attribution are in [`historic-icons`](../../historic-icons/).
