#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
# amnezia-dns-bridge
#
# AmneziaVPN's Linux helper configures DNS exclusively through the
# systemd-resolved D-Bus API (org.freedesktop.resolve1).  On systems without
# systemd-resolved that API is simply missing, so the helper cannot point the
# system resolver at the tunnel.  Because the helper *also* installs an
# iptables rule that rejects all DNS traffic which does not go through the
# tunnel, the end result is a total DNS blackout.
#
# This service implements the small subset of org.freedesktop.resolve1 that
# the AmneziaVPN helper actually uses and translates it to:
#
#   1. openresolv / resolvconf   (preferred, if installed)
#   2. direct /etc/resolv.conf management (fallback, with backup/restore)
#
# It must run as root on the system bus.  It deliberately refuses to start if
# something else already owns org.freedesktop.resolve1 (i.e. the real
# systemd-resolved), so it is safe to leave installed on systemd machines.

import argparse
import os
import shutil
import signal
import socket
import subprocess
import sys

try:
    import dbus
    import dbus.mainloop.glib
    import dbus.service
    from gi.repository import GLib
except ImportError:
    sys.stderr.write(
        "amnezia-dns-bridge: missing python3 modules (dbus-python, PyGObject)\n"
    )
    sys.exit(1)

try:
    from gi.repository import GLibUnix
    _signal_add = GLibUnix.signal_add
except ImportError:  # older PyGObject
    _signal_add = GLib.unix_signal_add

BUS_NAME = "org.freedesktop.resolve1"
OBJECT_PATH = "/org/freedesktop/resolve1"
IFACE = "org.freedesktop.resolve1.Manager"
PROPS_IFACE = "org.freedesktop.DBus.Properties"

RESOLV_CONF = os.environ.get("AMNEZIA_DNS_BRIDGE_RESOLV_CONF", "/etc/resolv.conf")
STATE_DIR = os.environ.get("AMNEZIA_DNS_BRIDGE_STATE_DIR", "/var/lib/amneziavpn")
BACKUP_CONF = os.path.join(STATE_DIR, "resolv.conf.bak")
BACKUP_META = os.path.join(STATE_DIR, "resolv.conf.meta")
RESOLVCONF_TAG = "amneziavpn"
# Useful on systems where resolvconf exists but is not the source of truth.
FORCE_FILE = os.environ.get("AMNEZIA_DNS_BRIDGE_FORCE_FILE") == "1"


def log(message):
    print("[amnezia-dns-bridge] %s" % message, flush=True)


def have(cmd):
    return shutil.which(cmd) is not None


class ResolveManager(dbus.service.Object):
    """Minimal org.freedesktop.resolve1.Manager implementation."""

    def __init__(self, bus):
        super().__init__(bus, OBJECT_PATH)
        # ifindex -> {"dns": [str], "domains": [(str, bool)], "default_route": bool}
        self.links = {}
        self.order = []
        self.backend = None

    # ------------------------------------------------------------------ state

    def _link(self, ifindex):
        ifindex = int(ifindex)
        if ifindex not in self.links:
            self.links[ifindex] = {
                "dns": [],
                "domains": [],
                "default_route": False,
            }
            self.order.append(ifindex)
        return self.links[ifindex]

    @staticmethod
    def _ifname(ifindex):
        try:
            return socket.if_indextoname(int(ifindex))
        except OSError:
            return None

    def _active_index(self):
        # Prefer the most recently configured link that is a default route.
        for ifindex in reversed(self.order):
            link = self.links.get(ifindex)
            if link and link["default_route"] and link["dns"]:
                return ifindex
        for ifindex in reversed(self.order):
            link = self.links.get(ifindex)
            if link and link["dns"]:
                return ifindex
        return None

    def _render(self):
        ifindex = self._active_index()
        if ifindex is None:
            return None
        link = self.links[ifindex]
        lines = []
        for address in link["dns"]:
            lines.append("nameserver %s" % address)
        for domain, search in link["domains"]:
            if domain in ("", "."):
                continue
            lines.append("%s %s" % ("search" if search else "domain", domain))
        return "\n".join(lines) + "\n"

    # ---------------------------------------------------------------- backend

    def _resolvconf(self, args, content=None):
        try:
            subprocess.run(
                ["resolvconf"] + args,
                input=content.encode() if content is not None else None,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=True,
            )
            return True
        except (OSError, subprocess.CalledProcessError) as exc:
            log("resolvconf %s failed: %s" % (" ".join(args), exc))
            return False

    def _apply(self):
        content = self._render()
        if content is None:
            self._revert()
            return

        if have("resolvconf") and not FORCE_FILE:
            # openresolv understands -x (exclusive) and -m (metric).  Debian's
            # resolvconf does not, so fall back to the portable form.
            ok = self._resolvconf(
                ["-a", RESOLVCONF_TAG, "-x", "-m", "0"], content
            ) or self._resolvconf(["-a", RESOLVCONF_TAG], content)
            if ok:
                self.backend = "resolvconf"
                log("DNS applied via resolvconf:\n%s" % content.rstrip())
                return

        self._write_direct(content)
        self.backend = "file"

    def _write_direct(self, content):
        os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)

        if not os.path.exists(BACKUP_META):
            meta = "file"
            if os.path.islink(RESOLV_CONF):
                meta = "symlink:" + os.readlink(RESOLV_CONF)
            with open(BACKUP_META, "w", encoding="utf-8") as handle:
                handle.write(meta + "\n")
            if os.path.exists(RESOLV_CONF):
                shutil.copy2(RESOLV_CONF, BACKUP_CONF, follow_symlinks=True)
            else:
                open(BACKUP_CONF, "w").close()

        # A symlink (e.g. to /run/systemd/resolve/stub-resolv.conf) would send
        # our writes to a file owned by another daemon.  Replace it.
        if os.path.islink(RESOLV_CONF):
            os.unlink(RESOLV_CONF)

        tmp = RESOLV_CONF + ".amneziavpn.tmp"
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, RESOLV_CONF)
        log("DNS applied directly to /etc/resolv.conf:\n%s" % content.rstrip())

    def _revert(self):
        if self.backend == "resolvconf":
            self._resolvconf(["-d", RESOLVCONF_TAG])
            self.backend = None
            return

        if not os.path.exists(BACKUP_META):
            self.backend = None
            return

        try:
            with open(BACKUP_META, encoding="utf-8") as handle:
                meta = handle.read().strip()
        except OSError:
            meta = "file"

        if meta.startswith("symlink:"):
            target = meta[len("symlink:"):]
            try:
                if os.path.lexists(RESOLV_CONF):
                    os.unlink(RESOLV_CONF)
                os.symlink(target, RESOLV_CONF)
            except OSError as exc:
                log("could not restore symlink %s: %s" % (target, exc))
        elif os.path.exists(BACKUP_CONF):
            shutil.copy2(BACKUP_CONF, RESOLV_CONF)

        for path in (BACKUP_META, BACKUP_CONF):
            try:
                os.unlink(path)
            except OSError:
                pass
        self.backend = None
        log("restored the previous /etc/resolv.conf")

    def _drop(self, ifindex):
        ifindex = int(ifindex)
        self.links.pop(ifindex, None)
        try:
            self.order.remove(ifindex)
        except ValueError:
            pass
        if not self.links:
            self._revert()
        else:
            self._apply()

    # ------------------------------------------------------------ D-Bus API

    def _set_dns(self, ifindex, addresses):
        parsed = []
        for family, raw in addresses:
            raw = bytes(raw)
            if family == socket.AF_INET and len(raw) == 4:
                parsed.append(socket.inet_ntop(socket.AF_INET, raw))
            elif family == socket.AF_INET6 and len(raw) == 16:
                parsed.append(socket.inet_ntop(socket.AF_INET6, raw))
        self._link(ifindex)["dns"] = parsed
        log("SetLinkDNS(%s, %s)" % (ifindex, ", ".join(parsed) or "-"))
        self._apply()

    @dbus.service.method(IFACE, in_signature="ia(iay)", out_signature="")
    def SetLinkDNS(self, ifindex, addresses):
        self._set_dns(ifindex, addresses)

    @dbus.service.method(IFACE, in_signature="ia(iay)us", out_signature="")
    def SetLinkDNSEx(self, ifindex, addresses, port, name):
        self._set_dns(ifindex, addresses)

    @dbus.service.method(IFACE, in_signature="ia(sb)", out_signature="")
    def SetLinkDomains(self, ifindex, domains):
        parsed = [(str(domain), bool(search)) for domain, search in domains]
        self._link(ifindex)["domains"] = parsed
        log("SetLinkDomains(%s, %s)" % (ifindex, parsed or "-"))
        self._apply()

    @dbus.service.method(IFACE, in_signature="ib", out_signature="")
    def SetLinkDefaultRoute(self, ifindex, enable):
        self._link(ifindex)["default_route"] = bool(enable)
        log("SetLinkDefaultRoute(%s, %s)" % (ifindex, bool(enable)))
        self._apply()

    @dbus.service.method(IFACE, in_signature="i", out_signature="")
    def RevertLink(self, ifindex):
        log("RevertLink(%s)" % ifindex)
        self._drop(ifindex)

    @dbus.service.method(IFACE, in_signature="i", out_signature="")
    def RevertLinkDNS(self, ifindex):
        log("RevertLinkDNS(%s)" % ifindex)
        self._drop(ifindex)

    @dbus.service.method(IFACE, in_signature="", out_signature="")
    def FlushCaches(self):
        # Optional: nscd / dnsmasq caches are flushed by the helper itself.
        if have("nscd"):
            subprocess.run(["nscd", "-i", "hosts"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # ------------------------------------------------------------ properties

    def _domains_variant(self):
        items = []
        for ifindex in self.order:
            for domain, search in self.links[ifindex]["domains"]:
                items.append(dbus.Struct(
                    (dbus.Int32(ifindex), dbus.String(domain), dbus.Boolean(search)),
                    signature="isb",
                ))
        return dbus.Array(items, signature="(isb)")

    def _dns_variant(self):
        items = []
        for ifindex in self.order:
            for address in self.links[ifindex]["dns"]:
                packed = socket.inet_pton(
                    socket.AF_INET6 if ":" in address else socket.AF_INET,
                    address,
                )
                items.append(dbus.Struct(
                    (
                        dbus.Int32(socket.AF_INET6 if ":" in address else socket.AF_INET),
                        dbus.Array([dbus.Byte(b) for b in packed], signature="y"),
                    ),
                    signature="iay",
                ))
        return dbus.Array(items, signature="(iay)")

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        if prop == "Domains":
            return self._domains_variant()
        if prop == "DNS":
            return self._dns_variant()
        if prop == "DNSEx":
            return dbus.Array([], signature="(iayus)")
        if prop == "FallbackDNS":
            return dbus.Array([], signature="(iay)")
        raise dbus.exceptions.DBusException(
            "Unknown property %s" % prop,
            name="org.freedesktop.DBus.Error.InvalidArgs",
        )

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return {
            "Domains": self._domains_variant(),
            "DNS": self._dns_variant(),
            "DNSEx": dbus.Array([], signature="(iayus)"),
            "FallbackDNS": dbus.Array([], signature="(iay)"),
        }

    # -------------------------------------------------------------- watchdog

    def watchdog(self):
        gone = [ifindex for ifindex in list(self.links)
                if self._ifname(ifindex) is None]
        for ifindex in gone:
            log("interface %s disappeared, reverting DNS" % ifindex)
            self._drop(ifindex)
        return True


def main():
    parser = argparse.ArgumentParser(description="org.freedesktop.resolve1 shim")
    parser.add_argument("--no-watchdog", action="store_true",
                        help="do not poll for vanished tunnel interfaces")
    parser.add_argument("--bus", choices=("system", "session"), default="system",
                        help="which D-Bus to use (session is for tests only)")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if args.bus == "system" and os.geteuid() != 0:
        log("must be run as root")
        return 1

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SystemBus() if args.bus == "system" else dbus.SessionBus()
    except dbus.exceptions.DBusException as exc:
        log("cannot connect to the %s bus: %s" % (args.bus, exc))
        return 1

    try:
        # Keep a reference: dropping it would release the bus name.
        bus_name = dbus.service.BusName(
            BUS_NAME,
            bus,
            do_not_queue=True,
            allow_replacement=False,
            replace_existing=False,
        )
    except dbus.exceptions.NameExistsException:
        log("%s is already owned (systemd-resolved is running); nothing to do"
            % BUS_NAME)
        return 0

    manager = ResolveManager(bus)
    log("ready: serving %s on the %s bus" % (BUS_NAME, args.bus))

    loop = GLib.MainLoop()

    def quit_handler(signum):
        log("signal %s received, restoring DNS" % signum)
        manager._revert()
        loop.quit()
        return False

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            _signal_add(GLib.PRIORITY_HIGH, signum,
                        lambda s=signum: quit_handler(s))
        except AttributeError:
            signal.signal(signum, lambda s, _f: quit_handler(s))

    if not args.no_watchdog:
        GLib.timeout_add_seconds(2, manager.watchdog)

    try:
        loop.run()
    finally:
        manager._revert()
    return 0


if __name__ == "__main__":
    sys.exit(main())
