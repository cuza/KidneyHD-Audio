#!/bin/sh
# Removes KidneyHD Audio: the driver and the control service. Run with sudo.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
launchctl bootout system /Library/LaunchDaemons/dev.cuza.kidneyhd-audiod.plist 2>/dev/null || true
rm -rf /Library/Audio/Plug-Ins/HAL/KidneyHDAudio.driver /Library/LaunchDaemons/dev.cuza.kidneyhd-audiod.plist "/Library/Application Support/KidneyHD Audio" \
  /var/run/kidneyhd-audiod.sock
pkgutil --forget dev.cuza.kidneyhd-audio >/dev/null 2>&1 || true
killall -9 coreaudiod 2>/dev/null || true
echo "KidneyHD Audio removed"
