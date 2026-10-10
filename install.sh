#!/usr/bin/env bash
#
# Setup: Pi Zero W + Camera Module 3 + Waveshare 4inch e-Paper HAT+ (E)
# Run on a fresh Raspberry Pi OS Lite (Trixie, 32-bit).
#
# Usage (run from the cloned repository):
#   chmod +x install.sh
#   ./install.sh               <- WITHOUT sudo
#   ./install.sh --skip-apt    only copy the scripts and set up the services (updates)
#
set -euo pipefail

SKIP_APT=0
[ "${1:-}" = "--skip-apt" ] && SKIP_APT=1

if [ "$EUID" -eq 0 ]; then
    echo "Please run without sudo (sudo is used internally)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$SKIP_APT" -eq 0 ]; then
    echo "=== 1/6: Updating system ==="
    sudo apt update
    sudo apt full-upgrade -y

    echo "=== 2/6: Enabling SPI ==="
    sudo raspi-config nonint do_spi 0
    # Camera: camera_auto_detect=1 is the default on Raspberry Pi OS.

    echo "=== 3/6: Installing packages (apt instead of pip, nothing to compile) ==="
    sudo apt install -y git unzip rpicam-apps \
        python3-pil python3-numpy python3-spidev python3-gpiozero
    sudo apt install -y python3-rpi.gpio || sudo apt install -y python3-rpi-lgpio
else
    echo "=== 1-3/6: Skipping system update and packages ==="
fi

echo "=== 4/6: Downloading Waveshare library ==="
cd "$HOME"
if [ ! -d "4inch_e-Paper_E" ]; then
    wget -q "https://files.waveshare.com/wiki/4inch-e-Paper-HAT%2B-(E)/4inch_e-Paper_E.zip"
    unzip -q 4inch_e-Paper_E.zip
    rm 4inch_e-Paper_E.zip
else
    echo "4inch_e-Paper_E already exists, skipping download."
fi

if ! find "$HOME/4inch_e-Paper_E" -type d -name waveshare_epd | grep -q .; then
    echo "ERROR: waveshare_epd not found - check the ZIP contents."
    exit 1
fi

echo "=== 5/6: Copying scripts + services ==="
SCRIPTS="zerocam.py camera_to_epaper.py zero_cam_server.py switch_shutdown.py optimize_boot.sh switch_to_networkd.sh"
if [ "$SCRIPT_DIR" != "$HOME" ]; then
    for f in $SCRIPTS; do
        cp "$SCRIPT_DIR/$f" "$HOME/"
    done
fi
if [ ! -f "$HOME/zero-cam.conf" ]; then
    cp "$SCRIPT_DIR/zero-cam.conf.example" "$HOME/zero-cam.conf"
    echo "Settings: $HOME/zero-cam.conf"
fi

sudo tee /etc/systemd/system/switch-shutdown.service > /dev/null <<EOF
[Unit]
Description=Shutdown via toggle switch (GPIO27)

[Service]
ExecStart=/usr/bin/python3 $HOME/switch_shutdown.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Web interface + photo triggers, runs as the normal user (groups gpio, spi, video).
# Does not wait for the network, so the button works as early as possible.
sudo tee /etc/systemd/system/zero-cam.service > /dev/null <<EOF
[Unit]
Description=Zero Cam: web interface and photo triggers
After=local-fs.target

[Service]
User=$USER
WorkingDirectory=$HOME
Environment=PYTHONUNBUFFERED=1
# higher priority: during boot the single CPU core is busy, the button should be ready early
Nice=-10
ExecStart=/usr/bin/python3 $HOME/zero_cam_server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# The web interface may shut the Pi down (and nothing else as root)
echo "$USER ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff" > /tmp/zero-cam.sudoers
if sudo visudo -cf /tmp/zero-cam.sudoers > /dev/null; then
    sudo install -m 440 -o root -g root /tmp/zero-cam.sudoers /etc/sudoers.d/zero-cam
fi
rm -f /tmp/zero-cam.sudoers

sudo systemctl daemon-reload
sudo systemctl enable switch-shutdown zero-cam
sudo systemctl restart zero-cam
echo "Services enabled. The shutdown switch is active after the next reboot."

echo "=== 6/6: Testing camera ==="
rpicam-hello --list-cameras || echo "WARNING: camera not detected, check the cable!"

echo ""
echo "=== Done! Now reboot: sudo reboot ==="
echo "Web interface: http://$(hostname).local:8080"
echo "Command line:  python3 ~/camera_to_epaper.py"
echo "Faster boot (optional): ~/optimize_boot.sh"
