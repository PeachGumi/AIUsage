#!/usr/bin/env python3
"""Build the AIUsage macOS icon from the checked-in master artwork."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs" / "icon.png"
APPICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def run(*arguments: str) -> None:
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL)


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"Icon master not found: {SOURCE}")

    APPICONSET.mkdir(parents=True, exist_ok=True)
    for name, size in SIZES.items():
        run(
            "/usr/bin/sips",
            "-z",
            str(size),
            str(size),
            str(SOURCE),
            "--out",
            str(APPICONSET / name),
        )

    print(APPICONSET)


if __name__ == "__main__":
    main()
