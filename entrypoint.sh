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
# restarts it. This loop polls cheaply for a change in the number of
# attached USB printer-class interfaces and restarts only the ipp-usb
# process (not the whole container) when it changes.
#
# Set WATCHDOG_INTERVAL=0 to disable this entirely if you'd rather not
# have the periodic wakeup at all.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-20}"

usb_printer_count() {
  grep -l '^07$' /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | wc -l
}

if [ "$WATCHDOG_INTERVAL" -gt 0 ]; then
  (
    last_count=$(usb_printer_count)
    while true; do
      sleep "$WATCHDOG_INTERVAL"
      current_count=$(usb_printer_count)
      if [ "$current_count" != "$last_count" ]; then
        echo "[watchdog] USB printer interface count changed ($last_count -> $current_count), restarting ipp-usb"
        pkill -f "ipp-usb standalone" 2>/dev/null || true
        sleep 1
        ipp-usb standalone &
        last_count="$current_count"
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