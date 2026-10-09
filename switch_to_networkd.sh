#!/usr/bin/env bash
#
# Replaces NetworkManager with systemd-networkd + wpa_supplicant for Wi-Fi.
#
# Why: On Raspberry Pi OS Trixie, NetworkManager runs "netplan generate" several
# times at startup. On the Pi Zero W (armv6) that takes about 17 s each, about
# 1 min per boot in total, before Wi-Fi comes up.
#
# Usage (run WITHOUT sudo, while connected via the current Wi-Fi):
#   ./switch_to_networkd.sh --dry-run   show what would be written, change nothing
#   ./switch_to_networkd.sh             switch (active after: sudo reboot)
#   ./switch_to_networkd.sh --undo      back to NetworkManager (active after reboot)
#
# Wi-Fi name, password, IP address (static or DHCP), gateway and DNS are taken
# from the current NetworkManager connection. The NetworkManager settings are
# kept, so --undo restores the previous state.
#
# Safety net: on the first boot after switching, a check waits up to 3 minutes
# for the network. If it does not come up, NetworkManager is restored
# automatically and the Pi reboots once more. If the network works, the check
# removes itself.
#
set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    echo "Please run without sudo (sudo is used internally)."
    exit 1
fi

DRY_RUN=0
UNDO=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    --undo) UNDO=1 ;;
    "") ;;
    *) echo "Unknown option: $1"; exit 1 ;;
esac

WPA_CONF=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
NETWORK_FILE=/etc/systemd/network/25-wlan0.network
WPA_DROPIN=/etc/systemd/system/wpa_supplicant@wlan0.service.d/zero-cam.conf
MODULES_FILE=/etc/modules-load.d/zero-cam-brcmfmac.conf
REVERT=/usr/local/sbin/zero-cam-use-networkmanager
CHECK=/usr/local/sbin/zero-cam-net-check
CHECK_UNIT=/etc/systemd/system/zero-cam-net-check.service

# --- Revert script: also used by the automatic check -------------------------
REVERT_SCRIPT='#!/bin/sh
# Switches Wi-Fi back from systemd-networkd to NetworkManager (zero-cam).
# Active after the next reboot.
systemctl disable systemd-networkd.service systemd-networkd.socket \
    systemd-networkd-wait-online.service wpa_supplicant@wlan0.service
systemctl unmask NetworkManager.service
systemctl enable NetworkManager.service NetworkManager-dispatcher.service wpa_supplicant.service
systemctl disable zero-cam-net-check.service
echo "NetworkManager restored, active after reboot."
'

if [ "$UNDO" -eq 1 ]; then
    if [ ! -x "$REVERT" ]; then
        echo "Nothing to undo ($REVERT not found)."
        exit 1
    fi
    sudo "$REVERT"
    echo "Reboot to apply: sudo reboot"
    exit 0
fi

# --- Read the current Wi-Fi connection ---------------------------------------
if systemctl is-active --quiet systemd-networkd && ! systemctl is-active --quiet NetworkManager; then
    echo "systemd-networkd is already in use."
    exit 0
fi

CON="$(nmcli -g GENERAL.CONNECTION device show wlan0)"
if [ -z "$CON" ]; then
    echo "ERROR: wlan0 is not connected - run this while the Wi-Fi works."
    exit 1
fi

# nmcli -g escapes ":" and "\\" in values
unescape() { sed 's/\\:/:/g; s/\\\\/\\/g'; }

SSID="$(nmcli -g 802-11-wireless.ssid con show "$CON" | unescape)"
HIDDEN="$(nmcli -g 802-11-wireless.hidden con show "$CON")"
KEY_MGMT="$(nmcli -g 802-11-wireless-security.key-mgmt con show "$CON")"
METHOD="$(nmcli -g ipv4.method con show "$CON")"
if [ "$KEY_MGMT" != "wpa-psk" ]; then
    echo "ERROR: only WPA/WPA2 with password (wpa-psk) is supported, found: '$KEY_MGMT'"
    exit 1
fi

if [ "$METHOD" = "manual" ]; then
    ADDRESS="$(nmcli -g ipv4.addresses con show "$CON" | cut -d, -f1)"
    GATEWAY="$(nmcli -g ipv4.gateway con show "$CON")"
else
    ADDRESS=""
    GATEWAY="$(nmcli -g IP4.GATEWAY device show wlan0)"
fi
DNS="$(nmcli -g IP4.DNS device show wlan0 | paste -sd ' ')"
DNS="${DNS:-$GATEWAY}"

COUNTRY="$(sed -n 's/.*cfg80211.ieee80211_regdom=\([A-Z][A-Z]\).*/\1/p' /proc/cmdline)"
COUNTRY="${COUNTRY:-$(raspi-config nonint get_wifi_country 2>/dev/null || true)}"
if [ -z "$COUNTRY" ]; then
    echo "ERROR: Wi-Fi country not set (sudo raspi-config nonint do_wifi_country DE)"
    exit 1
fi

# SSID as hex: no quoting problems with special characters
SSID_HEX="$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')"

if [ "$DRY_RUN" -eq 1 ]; then
    PSK_HEX="<derived from the stored password>"
else
    PSK="$(sudo nmcli -s -g 802-11-wireless-security.psk con show "$CON" | unescape)"
    if [[ "$PSK" =~ ^[0-9a-fA-F]{64}$ ]]; then
        PSK_HEX="$PSK"
    else
        # passphrase via stdin, so it does not show up in the process list
        PSK_HEX="$(printf '%s\n' "$PSK" | wpa_passphrase "$SSID" | sed -n 's/^\s*psk=\([0-9a-f]\{64\}\)$/\1/p')"
    fi
    unset PSK
    if ! [[ "$PSK_HEX" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "ERROR: could not read the Wi-Fi password."
        exit 1
    fi
fi

# --- Files -------------------------------------------------------------------
wpa_conf() {
    cat <<EOF
# Wi-Fi for systemd-networkd, written by zero-cam switch_to_networkd.sh
# SSID: $SSID
ctrl_interface=DIR=/run/wpa_supplicant GROUP=netdev
update_config=0
country=$COUNTRY

network={
    ssid=$SSID_HEX
    psk=$PSK_HEX
    key_mgmt=WPA-PSK
$([ "$HIDDEN" = "yes" ] && echo "    scan_ssid=1")
}
EOF
}

network_file() {
    echo "# written by zero-cam switch_to_networkd.sh"
    echo "[Match]"
    echo "Name=wlan0"
    echo ""
    echo "[Network]"
    if [ -n "$ADDRESS" ]; then
        echo "Address=$ADDRESS"
        echo "Gateway=$GATEWAY"
    else
        echo "DHCP=ipv4"
    fi
    for d in $DNS; do echo "DNS=$d"; done
    # IPv6 was off in NetworkManager as well
    echo "LinkLocalAddressing=no"
    echo "IPv6AcceptRA=no"
}

wpa_dropin() {
    cat <<'EOF'
# written by zero-cam switch_to_networkd.sh
[Service]
ExecStartPre=-/usr/sbin/rfkill unblock wlan
# Power saving makes the Wi-Fi of the Pi Zero W very slow to respond
ExecStartPost=-/usr/sbin/iw dev wlan0 set power_save off
EOF
}

# Without systemd-resolved nobody writes /etc/resolv.conf, so it becomes a fixed file
resolv_conf() {
    echo "# written by zero-cam switch_to_networkd.sh"
    for d in $DNS; do echo "nameserver $d"; done
}

check_script() {
    cat <<EOF
#!/bin/sh
# First boot after switching to systemd-networkd (zero-cam): if the network does
# not come up within 3 minutes, switch back to NetworkManager and reboot.
GATEWAY="$GATEWAY"
connected() {
    ping -c 1 -W 2 "\$GATEWAY" > /dev/null 2>&1 && return 0
    # router does not answer ping: associated and address set is enough
    /usr/sbin/wpa_cli -i wlan0 status 2>/dev/null | grep -q '^wpa_state=COMPLETED' &&
        ip -4 addr show wlan0 | grep -q inet
}
for i in \$(seq 1 36); do
    if connected; then
        # NetworkManager empties /etc/resolv.conf when it stops during the reboot,
        # so write it here, when NetworkManager is gone for sure
        cat > /etc/resolv.conf <<'RESOLV'
$(resolv_conf)
RESOLV
        echo "Network is up with systemd-networkd, removing the check."
        systemctl disable zero-cam-net-check.service
        exit 0
    fi
    sleep 5
done
echo "Network did not come up - restoring NetworkManager and rebooting."
$REVERT
systemctl reboot
EOF
}

check_unit() {
    cat <<EOF
[Unit]
Description=zero-cam: fall back to NetworkManager if Wi-Fi does not come up
After=network.target wpa_supplicant@wlan0.service systemd-networkd.service

[Service]
Type=oneshot
ExecStart=$CHECK
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
}

echo "Connection: $CON (SSID: $SSID, country: $COUNTRY)"
if [ -n "$ADDRESS" ]; then
    echo "IP: static $ADDRESS, gateway $GATEWAY, DNS $DNS"
else
    echo "IP: DHCP, DNS (fixed) $DNS"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    for f in WPA_CONF:wpa_conf NETWORK_FILE:network_file WPA_DROPIN:wpa_dropin \
             RESOLV:resolv_conf CHECK:check_script CHECK_UNIT:check_unit; do
        var="${f%%:*}"; func="${f#*:}"
        path="${!var:-/etc/resolv.conf}"
        echo ""
        echo "=== $path ==="
        "$func"
    done
    echo ""
    echo "=== $MODULES_FILE ==="
    echo "brcmfmac"
    echo ""
    echo "Dry run - nothing changed."
    exit 0
fi

# --- Write and switch --------------------------------------------------------
write() {  # write <path> <mode>, content from stdin
    sudo mkdir -p "$(dirname "$1")"
    sudo install -m "$2" /dev/stdin "$1"
}

wpa_conf | write "$WPA_CONF" 600
network_file | write "$NETWORK_FILE" 644
wpa_dropin | write "$WPA_DROPIN" 644
echo "brcmfmac" | write "$MODULES_FILE" 644
printf '%s' "$REVERT_SCRIPT" | write "$REVERT" 755
check_script | write "$CHECK" 755
check_unit | write "$CHECK_UNIT" 644

sudo cp /etc/resolv.conf /etc/resolv.conf.networkmanager

sudo systemctl daemon-reload
sudo systemctl disable NetworkManager.service NetworkManager-dispatcher.service wpa_supplicant.service
sudo systemctl mask NetworkManager.service
sudo systemctl enable systemd-networkd.service wpa_supplicant@wlan0.service zero-cam-net-check.service
# nothing here waits for the network
sudo systemctl disable systemd-networkd-wait-online.service

echo ""
echo "=== Done. Active after: sudo reboot ==="
echo "The first boot checks the network; if it fails, NetworkManager is restored"
echo "automatically and the Pi reboots once more (takes up to about 5 minutes)."
echo "Back manually: ./switch_to_networkd.sh --undo"
