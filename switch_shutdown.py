#!/usr/bin/env python3
"""
Shuts the Pi down cleanly as soon as the toggle switch is flipped to "off".

Wiring: toggle switch between GPIO27 (physical pin 13) and GND (pin 14).
No resistor needed (internal pull-up).
WARNING: do NOT use GPIO17/pin 11 - that is RST of the e-Paper display!

Runs as a systemd service (as root), set up by install.sh.
"""

import subprocess
from signal import pause

from gpiozero import Button

switch = Button(27, pull_up=True, bounce_time=0.2)


def shutdown():
    print("Switch off -> shutting down cleanly...")
    subprocess.run(["systemctl", "poweroff"])


switch.when_pressed = shutdown

print("Waiting for switch (GPIO27)...")
pause()
