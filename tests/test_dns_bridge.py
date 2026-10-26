#!/usr/bin/env python3
"""Smoke test for dns/amnezia-dns-bridge.py.

Run under a private session bus so the host /etc/resolv.conf is untouched:

    dbus-run-session -- python3 tests/test_dns_bridge.py
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import dbus

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "dns", "amnezia-dns-bridge.py")
BUS_NAME = "org.freedesktop.resolve1"
PATH = "/org/freedesktop/resolve1"
IFACE = "org.freedesktop.resolve1.Manager"


def wait_for_name(timeout=5.0):
    bus = dbus.SessionBus()
    dbus_obj = bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if dbus_obj.NameHasOwner(BUS_NAME):
            return True
        time.sleep(0.05)
    return False


def main():
    tmp = tempfile.mkdtemp(prefix="amnezia-dns-test-")
    resolv = os.path.join(tmp, "resolv.conf")
    state = os.path.join(tmp, "state")
    with open(resolv, "w", encoding="utf-8") as handle:
        handle.write("nameserver 192.0.2.1\n")

    env = dict(os.environ)
    env["AMNEZIA_DNS_BRIDGE_RESOLV_CONF"] = resolv
    env["AMNEZIA_DNS_BRIDGE_STATE_DIR"] = state
    env["AMNEZIA_DNS_BRIDGE_FORCE_FILE"] = "1"

    log = open(os.path.join(tmp, "bridge.log"), "w", encoding="utf-8")
    proc = subprocess.Popen(
        [sys.executable, BRIDGE, "--bus", "session", "--no-watchdog"],
        env=env,
        stdout=log,
        stderr=subprocess.STDOUT,
    )

    try:
        assert wait_for_name(), "bridge did not claim the bus name"
        bus = dbus.SessionBus()
        obj = bus.get_object(BUS_NAME, PATH)
        iface = dbus.Interface(obj, IFACE)
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")

        address = dbus.Array(
            [dbus.Byte(b) for b in socket.inet_pton(socket.AF_INET, "10.8.0.1")],
            signature="y",
        )
        iface.SetLinkDNS(
            2,
            dbus.Array(
                [dbus.Struct((dbus.Int32(socket.AF_INET), address), signature="iay")],
                signature="(iay)",
            ),
        )
        iface.SetLinkDomains(
            2,
            dbus.Array(
                [dbus.Struct((dbus.String("corp.example"), dbus.Boolean(True)),
                             signature="sb")],
                signature="(sb)",
            ),
        )
        iface.SetLinkDefaultRoute(2, True)

        content = open(resolv, encoding="utf-8").read()
        assert "nameserver 10.8.0.1" in content, content
        assert "search corp.example" in content, content

        domains = props.Get(IFACE, "Domains")
        assert len(domains) == 1, domains
        assert domains[0][0] == 2 and str(domains[0][1]) == "corp.example", domains

        iface.RevertLink(2)
        content = open(resolv, encoding="utf-8").read()
        assert "nameserver 192.0.2.1" in content, content

        # Apply again, then make sure SIGTERM restores the original file.
        iface.SetLinkDNS(
            2,
            dbus.Array(
                [dbus.Struct((dbus.Int32(socket.AF_INET), address), signature="iay")],
                signature="(iay)",
            ),
        )
        assert "nameserver 10.8.0.1" in open(resolv, encoding="utf-8").read()

        proc.terminate()
        proc.wait(timeout=5)
        content = open(resolv, encoding="utf-8").read()
        assert "nameserver 192.0.2.1" in content, content
        print("PASS: DNS bridge applies, reverts and restores on SIGTERM")
    finally:
        if proc.poll() is None:
            proc.kill()
        log.close()
        if proc.returncode not in (0, -15):
            print("--- bridge log ---")
            print(open(os.path.join(tmp, "bridge.log"), encoding="utf-8").read())
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
