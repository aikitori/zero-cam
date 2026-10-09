#!/usr/bin/env bash
#
# Setup: Pi Zero W + Camera Module 3 + Waveshare 4inch e-Paper HAT+ (E)
# Run on a fresh Raspberry Pi OS Lite (Trixie, 32-bit).
#
# Usage (install.sh, camera_to_epaper.py and switch_shutdown.py in the same folder):
#   chmod +x install.sh
#   ./install.sh          <- WITHOUT sudo
#
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "Please run without sudo (sudo is used internally)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

echo "=== 5/6: Copying scripts + shutdown switch service ==="
for f in camera_to_epaper.py switch_shutdown.py; do
    if [ -f "$SCRIPT_DIR/$f" ] && [ "$SCRIPT_DIR" != "$HOME" ]; then
        cp "$SCRIPT_DIR/$f" "$HOME/"
    fi
done

if [ -f "$HOME/switch_shutdown.py" ]; then
    sudo tee /etc/systemd/system/switch-shutdown.service > /dev/null <<EOF
[Unit]
Description=Shutdown via toggle switch (GPIO27)

[Service]
ExecStart=/usr/bin/python3 $HOME/switch_shutdown.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable switch-shutdown
    echo "Shutdown service enabled (starts after reboot)."
else
    echo "switch_shutdown.py not found - skipping service."
fi

echo "=== 6/6: Testing camera ==="
rpicam-hello --list-cameras || echo "WARNING: camera not detected, check the cable!"

echo ""
echo "=== Done! Now reboot: sudo reboot ==="
echo "Then: python3 ~/camera_to_epaper.py"
