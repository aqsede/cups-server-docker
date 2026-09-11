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

# --- CUPS runs in the foreground so the container stays up and handles
#     'docker compose stop' cleanly.
echo "[entrypoint] Starting cupsd..."
exec /usr/sbin/cupsd -f
