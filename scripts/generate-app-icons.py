#!/usr/bin/env python3
"""Render the approved SVGs into Xcode and SwiftPM app resources on macOS.

Development-only dependencies: Pillow and resvg-py==0.5.0. Ordinary app builds
use the checked-in outputs and do not need Python or an SVG renderer.
"""

import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image
import resvg_py


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "KestrelWebKit/Assets.xcassets"


def render(source, size, destination):
    # Supersampling retains smooth feather edges at small Dock/Finder sizes.
    png = resvg_py.svg_to_bytes(svg_path=str(source), width=size * 4, height=size * 4)
    image = Image.open(io.BytesIO(png)).convert("RGBA")
    image.resize((size, size), Image.Resampling.LANCZOS).save(destination)


def main():
    basic = ROOT / "resources/branding/kestrel-app-icon-basic.svg"
    dark = ROOT / "resources/branding/kestrel-app-icon-dark.svg"
    app_icons = ASSETS / "AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        render(basic, size, app_icons / f"icon_{size}x{size}.png")

    # Reuse the exact Xcode PNGs as the input for matching ICNS sizes.
    with tempfile.TemporaryDirectory(prefix="kestrel-icon-") as temporary:
        iconset = Path(temporary) / "Kestrel.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                suffix = "@2x" if scale == 2 else ""
                shutil.copyfile(app_icons / f"icon_{pixels}x{pixels}.png",
                                iconset / f"icon_{size}x{size}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o",
                        str(ROOT / "KestrelWebKit/Kestrel.icns")], check=True)

    for name, source in (("KestrelIconBasic", basic), ("KestrelIconDark", dark)):
        image_set = ASSETS / f"{name}.imageset"
        image_set.mkdir(exist_ok=True)
        images = []
        for scale in (1, 2):
            filename = f"icon@{scale}x.png"
            render(source, 512 * scale, image_set / filename)
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x"})
        (image_set / "Contents.json").write_text(json.dumps({
            "images": images, "info": {"author": "xcode", "version": 1},
            "properties": {"template-rendering-intent": "original"}
        }, indent=2) + "\n")


if __name__ == "__main__":
    main()
