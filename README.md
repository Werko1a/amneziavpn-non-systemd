**English** | [Русский](README.ru.md)

---

# amneziavpn-universal

Run the official **AmneziaVPN** client on Linux **without systemd** — Gentoo/OpenRC,
Void/runit, Artix, Alpine, Devuan, Slackware, and any other init system.

> Status: **tested (working)**. Base stack, services, and DNS bridge successfully
> verified on a live Artix Linux (OpenRC) system. See the "Testing" section below.

---

## Why this is needed

The core AmneziaVPN daemon (`AmneziaVPN-service`) has **no hard systemd calls**. It
is a standard Qt process communicating via Unix domain sockets. systemd is only
invoked in three places:

| Component | Location | Solution |
|---|---|---|
| Daemon startup & supervision | `deploy/data/linux/AmneziaVPN.service`, `systemctl` in `post_install.sh` | Native service files with auto-restart for any init system |
| DNS configuration | `client/platforms/linux/daemon/dnsutilslinux.cpp` — D-Bus `org.freedesktop.resolve1` | D-Bus bridge translating calls to `openresolv`/`/etc/resolv.conf` |
| Flushing DNS cache | `RouterLinux::flushDns()` — `systemctl restart nscd/systemd-resolved` | Silently ignored; bridge handles `nscd -i hosts` |

Due to the second point, **all DNS resolution completely breaks** upon connection:
the daemon installs an iptables chain (`amnvpn.a.310.blockDNS`) that drops outgoing
traffic on port 53 to prevent leaks, but fails to configure the system resolver.
This results in the common symptom: "VPN connected, but no Internet access".

## What the installer does

1. Locates `AmneziaVPN-service` in `/opt/AmneziaVPN` (or `--app-dir`).
2. Detects your running init system and installs a native service with **auto-restart (survives `kill -9`)**:
   - **OpenRC** — `/etc/init.d/amneziavpn` (`supervise-daemon`)
   - **runit** — `/etc/sv/amneziavpn` (`runsv` + logging via `svlogd`)
   - **s6** — `/etc/s6/sv/amneziavpn` (`s6-supervise`)
   - **dinit** — `/etc/dinit.d/amneziavpn` (native `restart = true`)
   - **SysVinit / Slackware** — `/etc/init.d/amneziavpn` (built-in watchdog supervisor)
   - **systemd** — unit with `Restart=always` (for systems without `systemd-resolved`)
3. Automatically purges `iptables` / `ip6tables` (parent rule jumps and custom chains across `filter`, `nat`, and `mangle` tables) upon service stop.
4. If `systemd-resolved` is absent — installs the `amnezia-dns-bridge` service:
   - claims the `org.freedesktop.resolve1` name on the D-Bus system bus;
   - redirects calls to `openresolv`, or safely modifies `/etc/resolv.conf` with automatic backup and restoration;
   - detects tunnel teardown and cleanly rolls back DNS changes.
5. Removes the conflicting official `/etc/systemd/system/AmneziaVPN.service` unit.
6. Installs the `/usr/local/bin/AmneziaVPN` wrapper (handling Wayland compatibility) and `.desktop` launcher.

## Quick Start

### 1. Extract the official `.run` package without running its installer

The official installer strictly invokes `systemctl`. We unpack it directly without running its scripts:

```bash
git clone https://github.com/Werko1a/amneziavpn-non-systemd.git amneziavpn-universal
cd amneziavpn-universal
chmod +x install.sh uninstall.sh fetch-app.sh

sudo ./fetch-app.sh --run ~/Downloads/AmneziaVPN_5.0.3.0_linux_x64.run
# or download and extract automatically:
# sudo ./fetch-app.sh --version 5.0.3.0
```

Extractor requires `p7zip` (or `7z`):

```bash
# Artix / Arch
sudo pacman -S p7zip
# Void
sudo xbps-install -S p7zip
# Gentoo
sudo emerge --ask app-arch/p7zip
```

### 2. Install services

```bash
sudo ./install.sh
```

Useful flags:

```bash
sudo ./install.sh --no-dns-bridge   # do not install DNS bridge (manual DNS setup)
sudo ./install.sh --force-x11       # force GUI under XWayland
sudo ./install.sh --no-start        # install services without starting them immediately
```

### 3. Verification

```bash
# OpenRC
sudo rc-service amneziavpn status
sudo rc-service amnezia-dns-bridge status

# runit
sudo sv status amneziavpn
sudo sv status amnezia-dns-bridge

# logs
tail -f /var/log/AmneziaVPN/AmneziaVPN-service.log
tail -f /var/log/AmneziaVPN/runit-amnezia-dns-bridge/current
```

Launch GUI: `AmneziaVPN` or `/usr/local/bin/AmneziaVPN`.

## Uninstallation

```bash
sudo ./uninstall.sh          # remove services, keep /opt/AmneziaVPN files
sudo ./uninstall.sh --purge  # remove everything completely
```

## About Wayland

The official `.run` bundle ships with its own Qt 6.10 build **without** the Wayland
platform plugin (`libqwayland`). The wrapper at `/usr/local/bin/AmneziaVPN` automatically
detects Wayland sessions and falls back to XWayland (`QT_QPA_PLATFORM=xcb`).

More details: [docs/wayland.md](docs/wayland.md).

## About DNS

For troubleshooting leaks and manual configuration: [docs/dns.md](docs/dns.md).

Quick check for DNS bridge status:

```bash
# current resolv.conf contents
cat /etc/resolv.conf

# verify bridge owns the D-Bus interface
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  string:org.freedesktop.resolve1
```

## Repository Structure

```
install.sh / uninstall.sh / fetch-app.sh
lib/common.sh                 init detection, binary discovery, template rendering
init/<init>/service.template  native service templates
dns/amnezia-dns-bridge.py     D-Bus shim for org.freedesktop.resolve1
dns/org.freedesktop.resolve1.conf  D-Bus policy (root access only)
docs/                         wayland, dns, s6, slackware
patches/                      native C++ patch (in progress)
```

## Testing

Tested and verified on a live **Artix Linux (OpenRC)** system:

- [x] service starts and survives `kill -9` (`supervise-daemon` respawns it instantly)
- [x] GUI client connects to daemon (no `Ipc::Init failed`)
- [x] `/etc/resolv.conf` receives VPN DNS servers after connecting
- [x] `dig +short example.com` resolves properly through the tunnel
- [x] `/etc/resolv.conf` is completely restored upon disconnecting
- [x] no leftover `amnvpn.*` chains or rules in `iptables -S` after service stop (full table cleanup)
- [x] boot autostart configured across all supported init systems

## License

GPL-3.0-or-later, matching the AmneziaVPN license.
