#!/usr/bin/env bash
#
# Shortens the boot time of the Pi Zero W by turning off services the camera
# does not need. Measured before: about 2:35 min until multi-user.target.
#
# Usage:
#   ./optimize_boot.sh          <- WITHOUT sudo
#   ./optimize_boot.sh --undo   turn everything back on (Wi-Fi back to DHCP)
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
#   swap file    see SWAP_DROPIN below
SERVICES="bluetooth.service udisks2.service NetworkManager-wait-online.service
e2scrub_reap.service rpi-eeprom-update.service"
TIMERS="apt-daily.timer apt-daily-upgrade.timer man-db.timer"

UNDO=0
STATIC=0
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

# Firmware: no rainbow splash, no extra delay before the kernel starts
if ! grep -q '^# zero-cam boot$' "$CONFIG"; then
    sudo tee -a "$CONFIG" > /dev/null <<'EOF'
# zero-cam boot
[all]
disable_splash=1
boot_delay=0
# zero-cam boot end
EOF
    echo "config.txt: disable_splash=1, boot_delay=0"
fi

echo ""
echo "=== Done. Reboot to apply: sudo reboot ==="
echo "Then check: systemd-analyze && systemd-analyze blame | head"
