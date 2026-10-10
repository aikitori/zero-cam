#!/usr/bin/env python3
"""
Takes a photo with the Raspberry Pi Camera Module 3 and shows it
in landscape orientation on the Waveshare 4inch e-Paper HAT+ (E).

Photos are kept in ~/photos. Settings: ~/zero-cam.conf (see zero-cam.conf.example).
Between two refreshes the script waits at least 180 s (Waveshare recommendation).

Requirements (handled by install.sh):
  - Raspberry Pi OS (Trixie), SPI enabled
  - Waveshare package extracted to ~/4inch_e-Paper_E
    (other location: set the EPD_LIB environment variable to the .../python/lib folder)
"""

import argparse
import subprocess

import zerocam


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--clear", action="store_true",
                        help="only set the display to white (no photo), e.g. before storing it")
    action.add_argument("--show", metavar="PHOTO",
                        help="show a saved photo (name from ~/photos or path to an image) instead of taking one")
    action.add_argument("--color-chart", action="store_true",
                        help="show one patch per panel color (to measure the real colors)")
    parser.add_argument("--force", action="store_true",
                        help="do not wait for the minimum interval between refreshes")
    args = parser.parse_args()

    config = zerocam.load_config()
    store = zerocam.PhotoStore(config)
    display = zerocam.Display(config)
    try:
        if args.clear:
            display.clear(force=args.force)
        elif args.color_chart:
            display.show(zerocam.color_chart(), force=args.force)
        else:
            name = args.show or zerocam.capture(config, store)
            if not args.show:
                print(f"Saved {store.original(name)}")
            display.show(zerocam.prepare(config, store, name), force=args.force)
        print("Done.")

    except subprocess.CalledProcessError as e:
        print(f"Camera capture failed: {e}")
    except (IOError, FileNotFoundError) as e:
        print(e)
    except KeyboardInterrupt:
        print("Aborted by user.")


if __name__ == "__main__":
    main()
