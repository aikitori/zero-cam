# Pi Zero e-Paper Camera

A Raspberry Pi Zero W takes a photo with the Camera Module 3 and shows it in landscape orientation on a 4" color e-Paper display. A toggle switch shuts the system down cleanly.

## Hardware

| Part | Details |
|---|---|
| Raspberry Pi Zero W (Rev 1.1) | armv6, 512 MB RAM, 2.4 GHz Wi-Fi only |
| Raspberry Pi Camera Module 3 (SC1223) | IMX708, 12 MP, autofocus |
| Zero camera cable | 22-pin (Zero) to 15-pin (camera), **not** included with the camera |
| Waveshare 4inch e-Paper HAT+ (E) | 600×400, E Ink Spectra 6, SPI, connected via 9-pin GH1.25 cable |
| Toggle switch | for clean shutdown |

## Wiring

### e-Paper (9-pin cable → GPIO header)

Go by the labels on the display board, not the cable colors.

| Display | Pi pin (physical) | Function |
|---|---|---|
| VCC | 17 | 3.3 V |
| GND | 20 | GND |
| DIN | 19 | GPIO10 / SPI MOSI |
| CLK | 23 | GPIO11 / SPI SCLK |
| CS | 24 | GPIO8 / SPI CE0 |
| DC | 22 | GPIO25 |
| RST | 11 | GPIO17 |
| BUSY | 18 | GPIO24 |
| PWR | 12 | GPIO18 |

### Toggle switch

| Switch | Pi pin (physical) |
|---|---|
| Contact 1 | 13 (GPIO27) |
| Contact 2 | 14 (GND) |

> ⚠️ Do **not** use GPIO17 / pin 11 – that is the display's RST.

Pin 1 is the square solder pad at the header corner next to the SD card slot.

## Installation

Starting point: a fresh **Raspberry Pi OS Lite (Trixie, 32-bit)**, flashed with Raspberry Pi Imager. Wi-Fi and SSH are configured directly in the Imager.

```bash
# from your PC
scp install.sh camera_to_epaper.py switch_shutdown.py <user>@<pi>:~/

# on the Pi
chmod +x install.sh
./install.sh        # run without sudo
sudo reboot
```

`install.sh` takes care of:
1. System update
2. Enabling SPI (`raspi-config nonint do_spi 0`)
3. Packages via apt (Pillow, NumPy, spidev, gpiozero, RPi.GPIO, rpicam-apps)
4. Downloading and extracting the Waveshare library to `~/4inch_e-Paper_E`
5. Setting up the systemd service `switch-shutdown`
6. Camera test

## Usage

```bash
python3 ~/camera_to_epaper.py
```

The script takes a photo (1200×800), center-crops it to 3:2, scales it to 600×400 and sends it to the display. The display then goes into sleep mode. A refresh takes about 20 s.

Configuration in `camera_to_epaper.py`:
- `ROTATION = 90` – change to `-90` if the image is upside down
- Environment variable `EPD_LIB` – path to `.../python/lib` if the Waveshare library is located elsewhere

Testing camera and display separately:
```bash
rpicam-hello --list-cameras
rpicam-still -o test.jpg
python3 $(find ~/4inch_e-Paper_E -name epd_4in0e_test.py)
```

## Files

| File | Purpose |
|---|---|
| `install.sh` | Complete setup on a fresh Raspberry Pi OS |
| `camera_to_epaper.py` | Take a photo and show it on the e-Paper |
| `switch_shutdown.py` | Shutdown via toggle switch (runs as a systemd service) |

## Known pitfalls

- **DietPi does not work with the camera.** Sensor and kernel driver are detected, but `rpicam-apps` aborts with "only supports the Raspberry Pi platforms". The cause is most likely the stripped-down GPU firmware `start_cd` (a result of `gpu_mem=16`). Without the full firmware, ISP and VCHI are missing and `bcm2835-isp` does not show up. Solution: use Raspberry Pi OS.
- **The Waveshare library is not in the GitHub repo `waveshare/e-Paper`.** `epd4in0e.py` is missing there. It has to be downloaded as a separate ZIP from the Waveshare wiki. Write the `+` in the URL as `%2B` and put the URL in quotes.
- **The ZIP already contains a `4inch_e-Paper_E` folder.** Using `unzip -d` therefore creates a double nesting. The script finds the path automatically.
- **Display orientation:** The internal buffer is portrait (400×600), so the landscape image is rotated before output.
- **Toggle switch:** The shutdown only triggers when the switch is flipped to "off". If the switch is already "off" at boot, flip it on and back off once.
- **Residual current after shutdown:** Even when shut down, the Pi still draws some current. To cut power completely, also disconnect the 5 V supply, but only once the green LED is off.

## Open items / ideas

- [ ] Confirm landscape rotation on real hardware
- [ ] Photo trigger (button, interval, motion sensor?)
- [ ] Image processing for the 6-color palette (boost contrast/saturation, dithering)
- [ ] Respect a minimum interval between refreshes (follow Waveshare's recommendation for Spectra 6)
- [ ] Optimize boot time (`systemd-analyze blame`, disable unneeded services)

## License

[AGPL-3.0](LICENSE)
