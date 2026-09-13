# Dockerized CUPS print server (driverless IPP-over-USB)

A small, purpose-built CUPS image for sharing a USB printer over the
network from a Debian 12 host, using **driverless IPP-over-USB**
(`ipp-usb`) instead of a vendor driver.

Built and verified end-to-end against a **Brother DCP-T220** on an
OpenMediaVault (Debian 12) NAS, but see [Compatibility](#compatibility)
below — nothing here is actually Brother-specific.

## Why driverless instead of a vendor driver?

Many USB printers/AIOs — the DCP-T220 included — either have no official
Linux driver, or ship one that's old, i386-only, or missing features
(no color option, etc.). Most of these same devices support
**IPP-over-USB**: the printer speaks the standard network printing
protocol (IPP) over the USB cable instead of a proprietary one.
`ipp-usb` bridges that to a local HTTP endpoint, and CUPS talks to it
using its universal **"IPP Everywhere"** driver — no vendor software
involved. No host modifications (such as blacklisting host drivers) are required.

## Files
- `Dockerfile` — Debian 12 slim + `cups` + `ipp-usb` + `avahi-daemon` + `inotify-tools`
- `cupsd.conf` — CUPS config: LAN admin access, sharing/mDNS enabled
- `entrypoint.sh` — seeds config on first run, starts dbus/avahi/ipp-usb/cupsd and event-driven watchdog
- `docker-compose.yml` — the stack file using volume-mapped USB bus access
- `.gitignore` — keeps `.env` and the `data/` runtime state out of git

## Setup

### 0. Set your own credentials

```bash
nano .env   # set CUPS_ADMIN_PASSWORD, TZ, etc.
```

`docker-compose.yml` reads from it automatically.

### 1. Plug in the printer
Connect it via USB and power it on. Confirm the host sees it:

```bash
lsusb
```

You should see a line for your printer's manufacturer (e.g. `Brother
Industries`). Note the `ID vvvv:pppp` — handy for troubleshooting.

### 2. Deploy

```bash
docker compose up -d --build
docker compose logs -f
```

### 3. Confirm `ipp-usb` found the printer

```bash
docker exec cups_server ipp-usb status
```

Expected output looks like:

```
ipp-usb daemon: running
ipp-usb devices:
 Num  Device              Vndr:Prod  Model
   1. Bus 003 Device 005  04f9:0474  "Brother DCP-T220"
      status: OK
```

If it shows no devices: recheck the cable, and make sure nothing on the
*host* (a leftover `ipp-usb`/`cups-browsed` install, or another
container) already has the USB interface claimed.

### 4. Add the printer in CUPS

Go to `http://<host-ip>:631` → **Administration → Add Printer**, log in
with the admin credentials from `docker-compose.yml`.

**In practice, the wizard's "Discovered Network Printers" list will
likely be empty** — this is a known limitation, not a bug in this
setup: `ipp-usb` advertises the device over mDNS on the *loopback*
interface, and Debian's `avahi-daemon` doesn't support loopback
advertising (some distros patch this in; Debian doesn't). So CUPS never
sees the auto-discovery announcement, even though `ipp-usb` itself is
working fine.

Add the queue directly instead. First find the local port `ipp-usb`
bound it to:

```bash
docker exec cups_server ls /var/log/ipp-usb/
docker exec cups_server grep -i "printer-uri" /var/log/ipp-usb/<device>.log
```

Look for a line like `printer-uri uri: http://localhost:60000/ipp/print`
— that port (`60000` in this example) is what you need next:

```bash
docker exec cups_server lpadmin -p My_Printer -E \
  -v ipp://localhost:60000/ipp/print \
  -m everywhere

docker exec cups_server lpadmin -p My_Printer -o printer-is-shared=true
```

Optional sanity check before adding — this should return `200 OK` with
printer attributes, confirming the bridge is alive:

```bash
docker exec cups_server ipptool -tv ipp://localhost:60000/ipp/print \
  get-printer-attributes.test
```

### 5. Print a test page

CUPS web UI → **Printers → My_Printer → Maintenance → Print Test Page**.

Other devices on the LAN should auto-discover it via Bonjour/mDNS —
confirmed working from macOS, iOS, and Android — since this
advertisement comes from **CUPS itself** on the real network interface,
not from `ipp-usb`'s loopback-only announcement. No further steps
needed on client devices in most cases.

## Compatibility

Nothing in the `Dockerfile`, `entrypoint.sh`, or `cupsd.conf` is
Brother- or T220-specific — this works for **any USB printer/AIO that
supports IPP-over-USB** (a large share of printers made in the last
~10 years across Brother, HP, Canon, Epson, etc.). If you're adapting
this for a different model:

- Rename the container/service in `docker-compose.yml` if you like —
  purely cosmetic.
- `lsusb` and `ipp-usb status` will show your device's own vendor/model
  string instead of `04f9:0474 "Brother DCP-T220"`.
- The manual `lpadmin` step (Step 4) applies to *every* Debian host,
  regardless of printer brand — it's a Debian `avahi` limitation, not a
  printer-specific one.
- If your printer does **not** support IPP-over-USB (older or
  budget models sometimes don't), `ipp-usb status` will simply show no
  devices, and you'd need a real vendor driver instead — outside the
  scope of this image, but you can install one inside the running
  container: `docker exec -it cups_server apt update && apt install
  printer-driver-all`.

## Notes & things worth knowing

- **Set a real `CUPS_ADMIN_PASSWORD` in `.env`** before you deploy — the
  current .env file ships with a trivial placeholder.
- **`network_mode: host`** is required for mDNS/Bonjour discovery to
  reach your real LAN (containers on the default bridge network can't
  send/receive multicast). This means port `631` binds directly on the
  host's interfaces. If the host isn't fully trusted-LAN-only, tighten
  `cupsd.conf`'s `Allow all` lines to your subnet, e.g.
  `Allow 192.168.1.0/24`.
- **Dynamic USB Access:** USB mounting is configured via `volumes:` (`/dev/bus/usb:/dev/bus/usb`) paired with `device_cgroup_rules: ['c 189:* rmw']`. Using `volumes:` instead of Docker's standard `devices:` block ensures that when a printer is physically unplugged and replugged, the newly assigned kernel device node is dynamically exposed inside the container without requiring a container restart.
- Nothing here touches host system files, systemd units, or (if
  applicable) your NAS software's own config — only the project folder
  and the `./data/` state directory are written to on the host.
- All state lives under `./data/` next to the compose file — back that
  up and printer config survives rebuilds or a host migration.

## Tested on
- OpenMediaVault (Debian 12 / Bookworm)
- Brother DCP-T220 (USB, vendor:product `04f9:0474`)
- Docker Compose v2, single-host deployment (not Swarm)

## Hotplug reliability (unplug/replug recovery)

`ipp-usb` relies on kernel udev notifications to detect USB connect/disconnect events. Because Docker containers lack a working udev socket, `ipp-usb` inside a container cannot natively detect when a printer is reconnected after an unplug or power-cycle.

This setup achieves **100% self-healing hotplug recovery** using a two-part approach:
1. **Dynamic USB Node Exposure:** `/dev/bus/usb` is mounted as a volume so new device paths created by the kernel are immediately visible inside the container.
2. **Event-Driven Watchdog:** `entrypoint.sh` runs a background task using `inotifywait` to monitor `/dev/bus/usb`. When a physical USB connect/disconnect occurs, `inotifywait` catches the event and cleanly restarts `ipp-usb`.

Unlike periodic polling loops, `inotifywait` uses kernel file-system events (`fsnotify`). It consumes **0% CPU** and triggers **zero wakeups** during idle.

## Putting the admin web UI behind Nginx Proxy Manager (LAN-only)

This gives you `https://cups.yourdomain.lan` instead of
`http://<nas-ip>:631` — cosmetic and a bit more secure (real TLS instead
of CUPS's self-signed cert warning), with **no effect on printing itself**.
mDNS discovery and actual IPP traffic go directly LAN-device → CUPS over
the real IP; NPM never sits in that path.

1. **Local DNS.** NPM doesn't provide DNS — something on your network
   needs to resolve `cups.yourdomain.lan` to NPM's IP (router's local DNS,
   Pi-hole, or a `/etc/hosts` entry per device). If you want a real,
   browser-trusted certificate rather than a self-signed one, use a domain
   you actually own with a DNS-01 challenge in NPM (Let's Encrypt can
   issue a cert for a name that only resolves internally, as long as you
   can prove ownership via a public DNS TXT record) — otherwise NPM's
   self-signed option works fine for a personal LAN page, just with a
   one-time browser warning to click through.

2. **In CUPS**, edit `cupsd.conf` and add your actual domain to
   `ServerAlias` (see the line already in this repo's `cupsd.conf` —
   replace `cups.example.lan` with your real one). If you already
   deployed before this change, edit the live copy at
   `./data/cups-config/cupsd.conf` on the host directly, then:
   ```bash
   docker compose restart
   ```

3. **In NPM**, add a new Proxy Host:
   - Domain Names: `cups.yourdomain.lan`
   - Scheme: `http`
   - Forward Hostname/IP: your NAS's real LAN IP (not `localhost`/`127.0.0.1`
     — CUPS is bound via `network_mode: host`, so it's reachable directly
     at the NAS's own address regardless of where NPM itself runs)
   - Forward Port: `631`
   - SSL tab: request/select your certificate, enable **Force SSL**

4. **Test:** visit `https://cups.yourdomain.lan`, log in with your admin
   credentials, and try an actual admin action (not just loading the
   page) — e.g. toggling a printer's shared state. If `ServerAlias` isn't
   set correctly you'll see a `400 Bad Request` rather than a login
   prompt, which is the tell that step 2 needs another look.

## Power consumption notes

- **Zero-CPU Idle Watchdog:** The `inotifywait` hotplug watcher is entirely event-driven via `fsnotify`. The process sits suspended in RAM with zero timer wakeups, allowing low-power NAS chips (e.g., Intel N100) to maintain deep CPU Package C-states (C8/C10).
- **No Mechanical Disk Spindown Blockers:** Logs are mounted as `tmpfs` (RAM) in `docker-compose.yml`, and CUPS's access/page logging is disabled by default. Routine background activity will not wake mechanical HDDs from standby.
- **mDNS/Bonjour behavior:** mDNS announcements occur only periodically based on TTL (tens of minutes) and during print job broadcasts. Avahi operates on passive UDP socket listeners on host network mode.
- **Printer Hardware Idle Draw:** The primary power consumption comes from the printer hardware remaining plugged into AC power (typically 1–2W idle draw depending on the printer model).