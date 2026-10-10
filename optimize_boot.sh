#!/usr/bin/env bash
#
# Shortens the boot time of the Pi Zero W by turning off services the camera
# does not need. Measured before: about 2:35 min until multi-user.target.
#
# Usage:
#   ./optimize_boot.sh          <- WITHOUT sudo
#   ./optimize_boot.sh --undo   turn everything back on (Wi-Fi back to DHCP)
#
# Further options with a small risk (if the Pi does not start any more: put the
# SD card into a PC and remove the "# zero-cam boot" block from config.txt):
#   --no-initramfs   boot without initramfs (10 MB less to load at every start);
#                    only if ext4 and the SD card driver are built into the kernel
#   --no-kms         no HDMI graphics driver (vc4-kms-v3d), the camera does not need it;
#                    measured on the Pi Zero W: no faster boot, but no HDMI console either
#
# Option: fixed IP address for Wi-Fi instead of DHCP (saves waiting for the lease):
#   ./optimize_boot.sh --static-ip                   keep the current address, gateway and DNS
#   ./optimize_boot.sh --static-ip 192.168.1.50/24 [--gateway 192.168.1.1] [--dns 192.168.1.1]
#   Missing values are taken from the current connection. Pick an address outside
#   the router's DHCP range (or reserve it there), otherwise it may be handed out twice.
#
# Afterwards: sudo reboot, then check with systemd-analyze / systemd-analyze blame
#
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "Please run without sudo (sudo is used internally)."
    exit 1
fi

CONFIG=/boot/firmware/config.txt
CMDLINE=/boot/firmware/cmdline.txt
# Swap only in compressed RAM (zram), without the backing file /var/swap on the SD card.
# The default (zram+file) recreates /var/swap with mkswap on every boot, ~20 s on the Pi Zero W.
SWAP_DROPIN=/etc/rpi/swap.conf.d/zero-cam.conf

# Not needed by the camera:
#   cloud-init   first-boot setup from Raspberry Pi Imager, ~30 s on every boot.
#                Wi-Fi and user stay configured (stored by NetworkManager).
#   bluetooth    no Bluetooth devices
#   udisks2      automounting USB drives
#   NetworkManager-wait-online   nothing here waits for the network
#   e2scrub_reap, rpi-eeprom-update (the Zero has no EEPROM)
#   apt-daily, apt-daily-upgrade, man-db timers: run shortly after boot and
#                slow down the single CPU core. Update manually with apt.
#   keyboard-setup, console-setup   no keyboard or screen
#   sshswitch    turns on SSH if a file "ssh" is on the boot partition (already on)
#   systemd-network-generator   network settings from the kernel command line (none)
#   swap file    see SWAP_DROPIN below
SERVICES="bluetooth.service udisks2.service NetworkManager-wait-online.service
e2scrub_reap.service rpi-eeprom-update.service keyboard-setup.service
console-setup.service sshswitch.service systemd-network-generator.service"
TIMERS="apt-daily.timer apt-daily-upgrade.timer man-db.timer"

UNDO=0
STATIC=0
NO_INITRAMFS=0
NO_KMS=0
ADDRESS=""
GATEWAY=""
DNS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --undo) UNDO=1 ;;
        --static-ip)
            STATIC=1
            if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then ADDRESS="$2"; shift; fi ;;
        --gateway) GATEWAY="${2:?--gateway needs an address}"; shift ;;
        --dns) DNS="${2:?--dns needs an address}"; shift ;;
        --no-initramfs) NO_INITRAMFS=1 ;;
        --no-kms) NO_KMS=1 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# Wi-Fi connection managed by NetworkManager (empty after switch_to_networkd.sh)
WIFI_CON="$(nmcli -g GENERAL.CONNECTION device show wlan0 2>/dev/null || true)"

if [ "$UNDO" -eq 1 ]; then
    if [ -n "$WIFI_CON" ] && [ "$(nmcli -g ipv4.method con show "$WIFI_CON")" = "manual" ]; then
        sudo nmcli con mod "$WIFI_CON" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        echo "Wi-Fi back to DHCP"
    fi
    sudo rm -f /etc/cloud/cloud-init.disabled "$SWAP_DROPIN"
    sudo systemctl enable $SERVICES $TIMERS
    sudo sed -i '/^# zero-cam boot$/,/^# zero-cam boot end$/d' "$CONFIG"
    sudo sed -i 's/^#zero-cam# //' "$CONFIG"
    sudo sed -i 's/ quiet\b//' "$CMDLINE"
    sudo sed -i 's|^\(\S\+\s\+/boot/firmware\s\+\S\+\s\+\S\+\s\+[0-9]\+\s\+\)0$|\12|' /etc/fstab
    echo "Undone. Reboot to apply: sudo reboot"
    exit 0
fi

if [ "$STATIC" -eq 1 ]; then
    if [ -z "$WIFI_CON" ]; then
        echo "ERROR: wlan0 is not connected via NetworkManager - cannot set a static IP."
        exit 1
    fi
    CURRENT="$(nmcli -g IP4.ADDRESS device show wlan0 | head -n 1)"
    ADDRESS="${ADDRESS:-$CURRENT}"
    case "$ADDRESS" in */*) ;; *) ADDRESS="$ADDRESS/${CURRENT#*/}" ;; esac
    GATEWAY="${GATEWAY:-$(nmcli -g IP4.GATEWAY device show wlan0)}"
    DNS="${DNS:-$(nmcli -g IP4.DNS device show wlan0 | paste -sd ' ')}"
    # Check the values before touching the only network connection
    python3 - "$ADDRESS" "$GATEWAY" $DNS <<'EOF' || exit 1
import ipaddress, sys
try:
    iface = ipaddress.ip_interface(sys.argv[1])
    gateway = ipaddress.ip_address(sys.argv[2])
    for dns in sys.argv[3:]:
        ipaddress.ip_address(dns)
except ValueError as e:
    sys.exit(f"ERROR: {e}")
if gateway not in iface.network:
    sys.exit(f"ERROR: gateway {gateway} is not in {iface.network}")
EOF
    sudo nmcli con mod "$WIFI_CON" ipv4.method manual ipv4.addresses "$ADDRESS" \
        ipv4.gateway "$GATEWAY" ipv4.dns "$DNS"
    echo "Wi-Fi ($WIFI_CON): static $ADDRESS, gateway $GATEWAY, DNS $DNS (active after reboot)"
fi

if [ ! -f /var/lib/cloud/instance/boot-finished ]; then
    echo "cloud-init has not finished the first-boot setup yet - not disabling it."
else
    sudo touch /etc/cloud/cloud-init.disabled
    echo "cloud-init disabled"
fi

sudo systemctl disable $SERVICES $TIMERS
echo "Disabled: $SERVICES $TIMERS" | tr '\n' ' '
echo

if [ ! -f "$SWAP_DROPIN" ]; then
    printf '# zero-cam: swap only in RAM (zram), no /var/swap\n[Main]\nMechanism=zram\n' \
        | sudo install -D -m 644 /dev/stdin "$SWAP_DROPIN"
    # still open as backing device until the reboot, the space is freed then
    sudo rm -f /var/swap
    echo "Swap: zram only, /var/swap removed"
fi

# Firmware (rewritten on every run, so new settings are added):
#   disable_splash, boot_delay=0   no rainbow splash, no extra delay before the kernel
#   initial_turbo=60   full CPU clock (1 GHz) for the first 60 s instead of starting
#                      at 700 MHz; no overclocking
#   disable-bt         Bluetooth drivers are not loaded at all
#   audio=off          no sound card (also skips alsa-restore)
EXTRA=""
if [ "$NO_INITRAMFS" -eq 1 ]; then
    # Without initramfs the kernel itself must mount the root file system
    if lsmod | grep -qE '^(ext4|mmc_block|sdhci|sdhci_iproc|bcm2835_mmc|bcm2835_sdhost) ' \
            || ! grep -qw ext4 /proc/filesystems \
            || ! findmnt -no SOURCE / | grep -q '^/dev/mmcblk'; then
        echo "ERROR: root file system needs modules from the initramfs - keeping it."
        exit 1
    fi
    EXTRA="${EXTRA}auto_initramfs=0
"
fi
# restore the graphics driver if a previous run switched it off
sudo sed -i 's/^#zero-cam# //' "$CONFIG"
if [ "$NO_KMS" -eq 1 ]; then
    # an overlay cannot be switched off by a later line, so comment it out (undo restores it)
    sudo sed -i 's/^dtoverlay=vc4-kms-v3d/#zero-cam# &/' "$CONFIG"
    EXTRA="${EXTRA}display_auto_detect=0
"
fi

sudo sed -i '/^# zero-cam boot$/,/^# zero-cam boot end$/d' "$CONFIG"
sudo tee -a "$CONFIG" > /dev/null <<EOF
# zero-cam boot
[all]
disable_splash=1
boot_delay=0
initial_turbo=60
dtoverlay=disable-bt
dtparam=audio=off
${EXTRA}# zero-cam boot end
EOF
echo "config.txt: disable_splash, boot_delay=0, initial_turbo=60, disable-bt, audio=off" \
    "$([ -n "$EXTRA" ] && echo "+ $EXTRA" | paste -sd' ')"

# Kernel: fewer messages on the serial console and screen
if ! grep -qw quiet "$CMDLINE"; then
    sudo sed -i '1s/$/ quiet/' "$CMDLINE"
    echo "cmdline.txt: quiet"
fi

# No file system check of the boot partition on every start (it is on the critical path)
if grep -qE '^\S+\s+/boot/firmware\s+\S+\s+\S+\s+[0-9]+\s+[1-9]$' /etc/fstab; then
    sudo cp /etc/fstab /etc/fstab.zero-cam-backup
    sudo sed -i 's|^\(\S\+\s\+/boot/firmware\s\+\S\+\s\+\S\+\s\+[0-9]\+\s\+\)[1-9]$|\10|' /etc/fstab
    echo "fstab: no check of /boot/firmware at boot"
fi

echo ""
echo "=== Done. Reboot to apply: sudo reboot ==="
echo "Then check: systemd-analyze && systemd-analyze blame | head"
