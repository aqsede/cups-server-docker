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
involved.

## Files
- `Dockerfile` — Debian 12 slim + `cups` + `ipp-usb` + `avahi-daemon`
- `cupsd.conf` — CUPS config: LAN admin access, sharing/mDNS enabled
- `entrypoint.sh` — seeds config on first run, starts dbus/avahi/ipp-usb/cupsd
- `docker-compose.yml` — the stack file
- `.gitignore` — keeps `.env` and the `data/` runtime state out of git

## Setup

### 0. Set your own credentials

```bash
nano .env   # set CUPS_ADMIN_PASSWORD, TZ, etc.
```

`docker-compose.yml` should reads from it automatically.

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
- **USB access** uses `device_cgroup_rules: ['c 189:* rmw']` rather than
  `privileged: true` — narrower than full privileged mode while still
  giving `ipp-usb` the raw access it needs (OpenPrinting's own
  recommended approach for containerizing `ipp-usb`).
- Nothing here touches host system files, systemd units, or (if
  applicable) your NAS software's own config — only the project folder
  and the `./data/` state directory are written to on the host.
- All state lives under `./data/` next to the compose file — back that
  up and printer config survives rebuilds or a host migration.

## Tested on
- OpenMediaVault (Debian 12 / Bookworm)
- Brother DCP-T220 (USB, vendor:product `04f9:0474`)
- Docker Compose v2, single-host deployment (not Swarm)

## Hotplug reliability (unplug/replug without restarting the container)

`ipp-usb` normally relies on `libusb`'s udev-based hotplug notifications
to notice a device being unplugged and replugged. **That notification
path is known to be unreliable inside Docker containers** — it's a
long-standing, well-documented limitation (see upstream reports at
`moby/moby#35359` and `libusb/libusb#559`), not something specific to
this setup. Containers don't get a working udev socket the way the host
does, so `ipp-usb` can be left "blind" to the printer coming back until
something restarts it.

This image works around it with a small watchdog loop in
`entrypoint.sh`: every `WATCHDOG_INTERVAL` seconds (default `20`, set via
`.env`) it compares what `ipp-usb` currently reports against what the
kernel actually sees attached (`/sys/bus/usb/devices/*/bInterfaceClass ==
07`). If they disagree, it restarts just the `ipp-usb` process, not the
whole container. Checking on every cycle - rather than only reacting once
to a plug/unplug event - matters because a restart can itself race with
the kernel still releasing the previous process's USB claim and come up
empty; an edge-triggered check would then lock in that wrong state until
another physical unplug/replug, whereas checking every cycle means a
failed attempt just gets retried on the next one.

Trade-off, stated plainly: this adds one small periodic CPU wakeup every
`WATCHDOG_INTERVAL` seconds, forever, in exchange for the printer working
again within ~20s of being replugged instead of requiring a manual
`docker compose restart`. If you'd rather not pay that (e.g. the printer
is permanently plugged in and never removed), set
`WATCHDOG_INTERVAL=0` to disable the loop entirely.

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

- **The CUPS/ipp-usb/avahi/dbus processes are idle, event-driven daemons**
  — near-zero CPU when nothing is printing, tens of MB of RAM. On an N100
  already running many containers, this isn't independently measurable
  against your baseline.
- **mDNS/Bonjour announcements are not continuous.** Re-announcements
  happen roughly every half the record's TTL (tens of minutes), not every
  second — it's push-based, not a polling loop.
- **Logs are mounted as `tmpfs` (RAM), not bind-mounted to disk.** CUPS's
  `AccessLog`/`PageLog` are also disabled outright (only real errors are
  kept). Combined, routine operation should never trigger a disk
  spin-up/D3 exit purely for logging. If you want `ipp-usb`'s own log
  verbosity turned down too (it's fairly chatty at the default `debug`
  level, though it only writes when there's actual print/scan traffic),
  edit `./data/ipp-usb-conf/ipp-usb.conf` on the host:

  ```ini
  [logging]
  device-log    = error
  main-log      = error
  console-log   = error
  max-file-size = 64K
  max-backup-files = 1
  ```

  then `docker compose restart`.
- **The one real, if modest, power cost is leaving the printer physically
  powered on 24/7** so `ipp-usb` can always see it — that's the printer's
  own idle draw (typically 1-2W for a small inkjet), independent of the
  container. A held-open USB session can also prevent USB autosuspend and
  block the host's deepest CPU/platform idle states to some degree; if you
  want to know how much that actually matters on your specific N100,
  compare `sudo powertop`'s package C-state residency with the printer
  plugged in vs. unplugged rather than taking an estimate — it varies
  enough by platform that a real measurement beats a guess.