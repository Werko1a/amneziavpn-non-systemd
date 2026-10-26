#!/usr/bin/env bash
# Runs the test suite. No root, no system bus, no /etc/resolv.conf changes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== shell syntax =="
for f in "$ROOT"/install.sh "$ROOT"/uninstall.sh "$ROOT"/fetch-app.sh "$ROOT"/lib/common.sh; do
    bash -n "$f"
done

echo "== python syntax =="
python3 -m py_compile "$ROOT"/dns/amnezia-dns-bridge.py "$ROOT"/tests/test_dns_bridge.py

echo "== DNS bridge (private session bus) =="
dbus-run-session -- python3 "$ROOT"/tests/test_dns_bridge.py

echo "all good"
