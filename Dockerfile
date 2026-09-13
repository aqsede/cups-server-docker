FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# cups            - the print server itself
# cups-client     - lpadmin/lpstat/lpinfo CLI tools
# cups-filters    - PDF/raster filters, driverless PPD generator
# cups-ipp-utils  - ipptool etc. (handy for debugging)
# ipp-usb         - bridges an IPP-over-USB device (our Brother T220) to a local HTTP/IPP endpoint
# avahi-daemon    - mDNS/Bonjour so the shared printer is discoverable on your LAN
# dbus            - required by avahi-daemon
# usbutils        - gives us lsusb inside the container for troubleshooting
RUN apt-get update && apt-get install -y --no-install-recommends \
        cups \
        cups-client \
        cups-filters \
        cups-ipp-utils \
        ipp-usb \
        avahi-daemon \
        avahi-utils \
        dbus \
        usbutils \
        inotify-tools \
    && rm -rf /var/lib/apt/lists/*

# Our own cupsd.conf: listens on all interfaces, allows LAN admin access,
# turns on sharing/browsing so the printer advertises over the network.
COPY cupsd.conf /etc/cups/cupsd.conf

# Stash pristine copies of the config directories. We bind-mount host folders
# over /etc/cups, /etc/ipp-usb and /var/spool/cups for persistence, and an
# empty host folder would otherwise hide everything the packages just installed.
# The entrypoint copies these back in on first run only.
RUN cp -a /etc/cups /etc/cups.defaults \
 && cp -a /etc/ipp-usb /etc/ipp-usb.defaults \
 && cp -a /var/spool/cups /var/spool/cups.defaults

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 631

ENTRYPOINT ["/entrypoint.sh"]
