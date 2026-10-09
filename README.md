# Pi Zero e-Paper Camera

A Raspberry Pi Zero W takes a photo with the Camera Module 3 and shows it in landscape orientation on a 4" color e-Paper display. Photos are taken with a button, at a fixed interval, by a motion sensor or from a small web interface, which also lets you browse all photos. A toggle switch shuts the system down cleanly.

Inspired by [kaloyaan/reframe](https://github.com/kaloyaan/reframe). Since a Raspberry Pi Zero 2 is currently hard to get due to supply shortages, this version runs on the original Pi Zero W.

## Hardware

| Part | Details |
|---|---|
| Raspberry Pi Zero W (Rev 1.1) | armv6, 512 MB RAM, 2.4 GHz Wi-Fi only |
| Raspberry Pi Camera Module 3 (SC1223) | IMX708, 12 MP, autofocus |
| Zero camera cable | 22-pin (Zero) to 15-pin (camera), **not** included with the camera |
| Waveshare 4inch e-Paper HAT+ (E) | 600×400, E Ink Spectra 6, SPI, connected via 9-pin GH1.25 cable |
| Toggle switch | for clean shutdown |
| Push button (optional) | shutter |
| PIR motion sensor (optional) | e.g. HC-SR501, 3.3 V output |

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

### Shutter button (optional)

| Button | Pi pin (physical) |
|---|---|
| Contact 1 | 37 (GPIO26) |
| Contact 2 | 39 (GND) |

No resistor needed (internal pull-up). Another pin can be set in `~/zero-cam.conf` (`button_gpio`).

### Motion sensor (optional)

| PIR sensor | Pi pin (physical) |
|---|---|
| VCC | 2 (5 V) |
| OUT | 36 (GPIO16) |
| GND | 34 (GND) |

Off by default: set `motion_gpio = 16` in `~/zero-cam.conf`. The sensor output must be 3.3 V (true for the HC-SR501). At most one photo per display refresh interval is taken.

Pin 1 is the square solder pad at the header corner next to the SD card slot.

## Installation

Starting point: a fresh **Raspberry Pi OS Lite (Trixie, 32-bit)**, flashed with Raspberry Pi Imager. Wi-Fi and SSH are configured directly in the Imager.

```bash
# on the Pi
sudo apt install -y git
git clone https://github.com/aikitori/zero-cam.git
cd zero-cam
./install.sh        # run without sudo
sudo reboot
```

`install.sh` takes care of:
1. System update
2. Enabling SPI (`raspi-config nonint do_spi 0`)
3. Packages via apt (Pillow, NumPy, spidev, gpiozero, RPi.GPIO, rpicam-apps)
4. Downloading and extracting the Waveshare library to `~/4inch_e-Paper_E`
5. Copying the scripts to `~`, creating `~/zero-cam.conf` (only if missing) and setting up the systemd services `switch-shutdown` and `zero-cam`
6. Camera test

Updating later: `git pull && ./install.sh --skip-apt` (copies the scripts and restarts the service, keeps your settings).

## Usage

### Web interface

`http://<pi>.local:8080` (e.g. `http://eink-camera.local:8080`):
- browse all photos, open the original and the dithered version as shown on the display, download originals
- take a photo, clear the display
- send a saved photo to the display, delete photos
- set the minimum time between display refreshes (stored in `~/zero-cam-web.conf`, which overrides `~/zero-cam.conf`)

The web interface has no login. Only use it in a trusted network.

### Photo triggers

The service `zero-cam` (web interface + triggers) takes a photo when
- the button is pressed (GPIO26),
- the motion sensor fires (if `motion_gpio` is set),
- the interval has passed (if `interval_minutes` is set, e.g. `60`).

### Command line

```bash
python3 ~/camera_to_epaper.py                      # take a photo and show it
python3 ~/camera_to_epaper.py --clear              # only set the display to white
python3 ~/camera_to_epaper.py --show 2026-10-09_20-04-47   # show a saved photo again
python3 ~/camera_to_epaper.py --force              # do not wait for the refresh interval
```

### What happens with a photo

1. The camera takes a photo (1200×800). It is saved in `~/photos` (`YYYY-MM-DD_HH-MM-SS.jpg`), plus a thumbnail in `~/photos/thumbs`.
2. The photo is center-cropped to 3:2 and scaled to 600×400.
3. Image processing for the 6-color panel: auto contrast, brightness, contrast and saturation, then Floyd-Steinberg dithering to the panel colors. The palette mixes the ideal colors with the measured ones of the panel (idea from [pimoroni/inky](https://github.com/pimoroni/inky)), which keeps more detail in dark and colored areas. The result is saved in `~/photos/dithered`.
4. The image is sent to the display (about 20 s), then the display goes into sleep mode.

**Minimum interval:** Waveshare recommends at least 180 s between two refreshes. A photo is always taken right away; the display shows it once the interval has passed. If several requests come in meanwhile, only the newest one is shown. The command line waits as well (or use `--force`). The time of the last refresh is kept in `~/photos/.last_refresh`, so this also works across reboots.

### Settings

All settings are in `~/zero-cam.conf` (template: [`zero-cam.conf.example`](zero-cam.conf.example)), e.g. camera and display rotation, image processing, triggers and web port. After changes: `sudo systemctl restart zero-cam`.

Logs: `journalctl -u zero-cam -f`

`--clear` sets the display to white without taking a photo. Use it before storing the camera for a longer time, so no image stays on the display.

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
| `zerocam.py` | Shared code: settings, photo storage, capture, image processing, display |
| `camera_to_epaper.py` | Command line: take a photo / show a saved one / clear the display |
| `zero_cam_server.py` | Web interface and photo triggers (systemd service `zero-cam`) |
| `zero-cam.conf.example` | Settings template |
| `switch_shutdown.py` | Shutdown via toggle switch (runs as a systemd service) |
| `optimize_boot.sh` | Faster boot: turns off services the camera does not need, optional static IP |
| `switch_to_networkd.sh` | Faster boot: Wi-Fi via systemd-networkd instead of NetworkManager |

## Known pitfalls

- **DietPi does not work with the camera.** Sensor and kernel driver are detected, but `rpicam-apps` aborts with "only supports the Raspberry Pi platforms". The cause is most likely the stripped-down GPU firmware `start_cd` (a result of `gpu_mem=16`). Without the full firmware, ISP and VCHI are missing and `bcm2835-isp` does not show up. Solution: use Raspberry Pi OS.
- **The Waveshare library is not in the GitHub repo `waveshare/e-Paper`.** `epd4in0e.py` is missing there. It has to be downloaded as a separate ZIP from the Waveshare wiki. Write the `+` in the URL as `%2B` and put the URL in quotes.
- **The ZIP already contains a `4inch_e-Paper_E` folder.** Using `unzip -d` therefore creates a double nesting. The script finds the path automatically.
- **Display orientation:** The internal buffer is portrait (400×600), so the landscape image is rotated before output.
- **Waveshare's `getbuffer()` dithers again.** It quantizes to its own pure palette, which would destroy an image dithered with other colors. `zerocam.py` therefore builds the panel buffer itself.
- **Toggle switch:** The shutdown only triggers when the switch is flipped to "off". If the switch is already "off" at boot, flip it on and back off once.
- **Residual current after shutdown:** Even when shut down, the Pi still draws some current. To cut power completely, also disconnect the 5 V supply, but only once the green LED is off.

## Boot time

On a fresh Raspberry Pi OS the Pi Zero W needs about 2:35 min until everything is started (`systemd-analyze`). The biggest parts are cloud-init (about 30 s on every boot, only needed for the first setup) and NetworkManager (about 70 s).

```bash
~/optimize_boot.sh      # run without sudo, then: sudo reboot
~/optimize_boot.sh --undo
```

Optional: a fixed IP address for Wi-Fi instead of DHCP, so the Pi does not have to wait for a lease after connecting:

```bash
~/optimize_boot.sh --static-ip                    # keep the current address, gateway and DNS
~/optimize_boot.sh --static-ip 192.168.1.50/24 --gateway 192.168.1.1 --dns 192.168.1.1
```

Missing values are taken from the current connection; the values are checked before anything is changed, and the new address is active after the reboot. Pick an address outside the router's DHCP range (or reserve it in the router), otherwise it may be handed out twice. `--undo` switches back to DHCP. If the Pi is not reachable afterwards, the Wi-Fi settings are in `/etc/netplan/90-NM-*.yaml` on the SD card.

The script disables cloud-init, Bluetooth, udisks2, `NetworkManager-wait-online`, `e2scrub_reap`, `rpi-eeprom-update` and the apt and man-db timers, and turns off the rainbow splash. Wi-Fi and the user stay configured. Automatic package list updates are off afterwards: update with `sudo apt update && sudo apt full-upgrade`.

The `zero-cam` service does not wait for the network, so the button works before Wi-Fi is up.

### NetworkManager → systemd-networkd

Even after that, NetworkManager takes over a minute: on Raspberry Pi OS Trixie it runs `netplan generate` several times at startup, about 17 s each on the Pi Zero W (a known problem, see [this write-up](https://hallard.me/speed-up-boot-time-on-pi-zero-with-raspbian-trixie/) and [WLAN-Pi/pi-gen#111](https://github.com/WLAN-Pi/pi-gen/issues/111)). `switch_to_networkd.sh` replaces it with `systemd-networkd` + `wpa_supplicant`:

```bash
~/switch_to_networkd.sh --dry-run   # show the files it would write, change nothing
~/switch_to_networkd.sh             # switch, then: sudo reboot
~/switch_to_networkd.sh --undo      # back to NetworkManager, then: sudo reboot
```

Wi-Fi name, password (stored only as a hash), static IP or DHCP, gateway and DNS are taken from the current NetworkManager connection; its settings are kept for `--undo`. Only WPA/WPA2 with a password is supported. `/etc/resolv.conf` becomes a fixed file with the DNS server.

**Safety net:** on the first boot after switching, `zero-cam-net-check` waits up to 3 minutes for the network. If it does not come up, NetworkManager is restored and the Pi reboots once more, so it is reachable again after about 5 minutes. If the network works, the check removes itself. Still, have a way to reach the SD card in case something goes wrong.

## Open items / ideas

- [ ] Confirm landscape rotation on real hardware (camera: `[camera] rotation = 180` if the photo is upside down)
- [x] Photo trigger: button, interval, motion sensor
- [x] Image processing for the 6-color palette (contrast/saturation, dithering)
- [x] Respect a minimum interval between refreshes (180 s, Waveshare recommendation)
- [x] Optimize boot time (`optimize_boot.sh`)
- [ ] Boot time: test `switch_to_networkd.sh` on the real device and measure
- [x] Simple, lightweight web server (Python standard library, about 25 MB RAM):
  - browse the photos taken
  - web control (take a photo, clear the display)
  - send a saved photo to the e-Paper display

## License

[AGPL-3.0](LICENSE)
