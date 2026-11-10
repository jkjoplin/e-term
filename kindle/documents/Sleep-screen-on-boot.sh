#!/bin/sh
# Name: Sleep screen on boot
# Author: e-term
# DontUseFBInk

SRC=/mnt/us/extensions/custom-screensaver/boot.conf
DST=/etc/upstart/eterm-screensaver.conf

if [ ! -f "$SRC" ]; then
  echo "The sleep screen is not installed yet."
  exit 0
fi

mntroot rw || {
  echo "Could not make the system writable."
  exit 0
}
cp "$SRC" "$DST"
mntroot ro
echo "After the next reboot, the sleep screen comes back on its own."
echo "Open Custom Screensaver once if this reboot should use it immediately."
