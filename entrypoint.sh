#!/bin/bash
set -e

CUPS_ADMIN_USER="${CUPS_ADMIN_USER:-admin}"
CUPS_ADMIN_PASSWORD="${CUPS_ADMIN_PASSWORD:-admin}"

echo "[entrypoint] Starting Brother T220 CUPS print server..."

# --- Seed persistent volumes on first run --------------------------------
# Bind-mounting an empty host folder over these paths hides the files the
# apt packages just installed. Only copy defaults in if they're missing,
# so real config survives container recreation.
if [ ! -f /etc/cups/cupsd.conf ]; then
  echo "[entrypoint] First run: seeding /etc/cups"
  cp -a /etc/cups.defaults/. /etc/cups/
fi
if [ ! -f /etc/ipp-usb/ipp-usb.conf ]; then
  echo "[entrypoint] First run: seeding /etc/ipp-usb"
  cp -a /etc/ipp-usb.defaults/. /etc/ipp-usb/
fi
if [ ! -d /var/spool/cups/tmp ]; then
  echo "[entrypoint] First run: seeding /var/spool/cups"
  cp -a /var/spool/cups.defaults/. /var/spool/cups/
fi
chown -R root:lp /etc/cups /var/spool/cups 2>/dev/null || true

# --- dbus / avahi need a stable machine-id --------------------------------
[ -s /etc/machine-id ] || dbus-uuidgen --ensure=/etc/machine-id

# --- CUPS admin user, must be in the lpadmin group to manage printers ----
if ! id "$CUPS_ADMIN_USER" &>/dev/null; then
  useradd -m -s /usr/sbin/nologin "$CUPS_ADMIN_USER"
fi
echo "${CUPS_ADMIN_USER}:${CUPS_ADMIN_PASSWORD}" | chpasswd
usermod -aG lpadmin "$CUPS_ADMIN_USER"

# --- D-Bus (required by avahi-daemon) -------------------------------------
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --fork

# --- Avahi: advertises the shared printer over mDNS/Bonjour on your LAN --
avahi-daemon --daemonize --no-chroot

# --- ipp-usb: bridges the USB-connected Brother T220 to a local IPP endpoint
ipp-usb standalone &

sleep 3
echo "[entrypoint] ipp-usb device status:"
ipp-usb status || echo "[entrypoint] (no device detected yet - check that the printer is plugged in and powered on)"

# --- Lightweight USB hotplug watchdog -------------------------------------
# libusb's udev-based hotplug notifications are known to be unreliable
# inside Docker containers (see moby/moby#35359, libusb/libusb#559) - the
# container has no working udev socket for it to listen on. Without this,
# ipp-usb can be left "blind" after an unplug/replug until something
# restarts it.
#
# This checks, every cycle, whether what ipp-usb currently reports matches
# what the kernel actually sees - not just whether something changed since
# last time. That distinction matters: a restart can itself race with the
# kernel still releasing the old process's USB claim and silently come up
# empty, and a purely edge-triggered check would then lock in that wrong
# state until another physical unplug/replug. Checking on every cycle
# means a failed attempt just gets retried on the next one instead of
# getting stuck.
#
# Set WATCHDOG_INTERVAL=0 to disable this entirely if you'd rather not
# have the periodic wakeup at all.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-20}"

usb_printer_count() {
  grep -l '^07$' /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | wc -l
}

ipp_usb_reported_count() {
  ipp-usb status 2>/dev/null | grep -cE '^\s*[0-9]+\.\s'
}

restart_ipp_usb() {
  pkill -f "ipp-usb standalone" 2>/dev/null || true
  sleep 2
  ipp-usb standalone &
}

if [ "$WATCHDOG_INTERVAL" -gt 0 ]; then
  (
    while true; do
      sleep "$WATCHDOG_INTERVAL"
      kernel_count=$(usb_printer_count)
      reported_count=$(ipp_usb_reported_count)
      if [ "$kernel_count" != "$reported_count" ]; then
        echo "[watchdog] mismatch: kernel sees $kernel_count printer-class interface(s), ipp-usb reports $reported_count - restarting ipp-usb"
        restart_ipp_usb
      fi
    done
  ) &
  echo "[entrypoint] Hotplug watchdog running (checking every ${WATCHDOG_INTERVAL}s)"
else
  echo "[entrypoint] Hotplug watchdog disabled (WATCHDOG_INTERVAL=0)"
fi

# --- CUPS runs in the foreground so the container stays up and handles
#     'docker compose stop' cleanly.
echo "[entrypoint] Starting cupsd..."
exec /usr/sbin/cupsd -f