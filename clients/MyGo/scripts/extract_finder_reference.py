#!/usr/bin/env python3
"""Extract fixed, non-private component crops from the supplied lossless PNG.

Requires Pillow. No alignment, resizing, masking, or input overwriting.
Coordinates are device pixels relative to WINDOW; scale is exactly 2.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
from PIL import Image, ImageCms

SOURCE_SIZE = (2306, 1362)
WINDOW = (112, 76, 2194, 1214)
REGIONS = {
    "navigation": (368, 16, 514, 90),
    "view-mode": (1272, 16, 1568, 90),
    "search": (1990, 16, 2068, 90),
    "table-header-name": (436, 104, 522, 156),
    # Blank row interiors only; deliberately excludes all private file names.
    "table-stripes": (1000, 490, 1200, 650),
    "sidebar-label-desktop": (108, 310, 250, 348),
    "sidebar-icon-desktop": (30, 310, 110, 348),
}

def extract(source, output):
    source, output = Path(source), Path(output)
    raw = source.read_bytes()
    with Image.open(io.BytesIO(raw)) as im:
        if im.format != "PNG" or im.size != SOURCE_SIZE or im.mode not in ("RGB", "RGBA"):
            raise ValueError("expected original 2306x1362 RGB/RGBA lossless PNG; JPEG/resized inputs are refused")
        profile = im.info.get("icc_profile")
        if profile:
            im = ImageCms.profileToProfile(im, ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"), outputMode="RGBA")
        else:
            im = im.convert("RGBA")
        window = im.crop(WINDOW)
        output.mkdir(parents=True, exist_ok=True)
        for name, rect in REGIONS.items():
            # Save raw sRGB pixels, stripping the original device profile.
            crop = window.crop(rect)
            crop.info.clear()
            crop.save(output / (name + ".png"))
    provenance = {
        "sourceSHA256": hashlib.sha256(raw).hexdigest(),
        "sourcePixels": SOURCE_SIZE,
        "windowRectPixels": WINDOW,
        "devicePixelsPerPoint": 2,
        "colorSpace": "sRGB (ICC converted if source profile present)",
        "referenceState": "dark, list selected, back/forward disabled, four view modes enabled",
        "productionStateDifference": "columns/gallery remain disabled in MVP; primary comparison retains this difference",
        "regionsRelativeToWindowPixels": REGIONS,
        "scope": "isolated components only, not a full-window equality assertion",
    }
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    return provenance

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    extract(args.source, args.output)
