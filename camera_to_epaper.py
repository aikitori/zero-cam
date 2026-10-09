#!/usr/bin/env python3
"""
Takes a photo with the Raspberry Pi Camera Module 3 and shows it
in landscape orientation on the Waveshare 4inch e-Paper HAT+ (E).

Requirements (handled by install.sh):
  - Raspberry Pi OS (Trixie), SPI enabled
  - Waveshare package extracted to ~/4inch_e-Paper_E
    (other location: set the EPD_LIB environment variable to the .../python/lib folder)
"""

import os
import subprocess
import sys
import time
from pathlib import Path

# --- Locate the Waveshare library BEFORE importing it ----------------------
def _find_epd_lib():
    if os.environ.get("EPD_LIB"):
        return os.environ["EPD_LIB"]
    bases = [Path.home()]
    if os.environ.get("SUDO_USER"):
        bases.append(Path("/home") / os.environ["SUDO_USER"])
    for base in bases:
        for hit in (base / "4inch_e-Paper_E").glob("**/waveshare_epd"):
            return str(hit.parent)
    return None

_lib = _find_epd_lib()
if _lib:
    sys.path.insert(0, _lib)

from PIL import Image  # noqa: E402
from waveshare_epd import epd4in0e  # noqa: E402

PHOTO_PATH = Path("/tmp/photo.jpg")

# Visible orientation (landscape)
VISUAL_WIDTH = 600
VISUAL_HEIGHT = 400
# If the image is upside down, use -90 instead of 90
ROTATION = 90


def capture_photo():
    """Take a photo (3:2, matches the 600x400 display)."""
    print("Taking photo...")
    subprocess.run(
        [
            "rpicam-still",
            "-o", str(PHOTO_PATH),
            "--width", "1200",
            "--height", "800",
            "--nopreview",
            "-t", "1500",  # time for autofocus/exposure
        ],
        check=True,
    )


def prepare_image():
    """Load the photo, center-crop it to 3:2 and scale it to 600x400."""
    image = Image.open(PHOTO_PATH).convert("RGB")

    target_ratio = VISUAL_WIDTH / VISUAL_HEIGHT
    img_ratio = image.width / image.height

    if img_ratio > target_ratio:
        new_width = int(image.height * target_ratio)
        left = (image.width - new_width) // 2
        image = image.crop((left, 0, left + new_width, image.height))
    else:
        new_height = int(image.width / target_ratio)
        top = (image.height - new_height) // 2
        image = image.crop((0, top, image.width, top + new_height))

    return image.resize((VISUAL_WIDTH, VISUAL_HEIGHT), Image.LANCZOS)


def main():
    epd = None
    try:
        capture_photo()

        print("Initializing display...")
        epd = epd4in0e.EPD()
        epd.init()

        image = prepare_image()

        # Internal buffer is portrait (400x600) -> rotate the landscape image
        if epd.width != VISUAL_WIDTH:
            image = image.rotate(ROTATION, expand=True)

        print("Sending photo to display (~20 s refresh)...")
        epd.display(epd.getbuffer(image))
        time.sleep(2)
        print("Done.")

    except subprocess.CalledProcessError as e:
        print(f"Camera capture failed: {e}")
    except KeyboardInterrupt:
        print("Aborted by user.")
    finally:
        # Always put the display to sleep and release GPIO/5V, even on errors
        if epd is not None:
            try:
                epd.sleep()
            except Exception:
                epd4in0e.epdconfig.module_exit(cleanup=True)


if __name__ == "__main__":
    main()
