#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[2]
SOURCE_IMAGE = Path(__file__).resolve().parent / "ApodexisIconAI.png"
APPICON_DIR = ROOT / "Apodexis" / "Assets.xcassets" / "AppIcon.appiconset"
ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def square_crop(image: Image.Image) -> Image.Image:
    width, height = image.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    return image.crop((left, top, left + side, top + side))


def main() -> None:
    APPICON_DIR.mkdir(parents=True, exist_ok=True)
    source = square_crop(Image.open(SOURCE_IMAGE).convert("RGBA"))
    for size in ICON_SIZES:
        source.resize((size, size), Image.Resampling.LANCZOS).save(
            APPICON_DIR / f"AppIcon-{size}.png"
        )
    print(f"Wrote {len(ICON_SIZES)} app icon PNGs from {SOURCE_IMAGE}")


if __name__ == "__main__":
    main()
