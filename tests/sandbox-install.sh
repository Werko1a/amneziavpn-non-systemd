#!/usr/bin/env bash
# Sandboxed integration test for install.sh / uninstall.sh.
#
# Runs in a user+mount namespace and replaces /etc, /usr/local, /usr/share,
# /var and /run with tmpfs, so it never touches the host.
#
# Usage:
#   tests/sandbox-install.sh <init> [install|uninstall|both|twice]
#   START=1 tests/sandbox-install.sh <init> install
#
# <init> is one of: systemd openrc runit s6 dinit sysvinit slackware
# APP_DIR must point at an extracted AmneziaVPN tree (default /opt/AmneziaVPN).
set -euo pipefail

INIT="${1:?usage: sandbox-install.sh <init> [install|uninstall|both|twice]}"
MODE="${2:-install}"
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_DIR:-/opt/AmneziaVPN}"
STUBS="${STUBS:-$(mktemp -d)}"
LOG="$(mktemp -d)"

cleanup() { rm -rf "$STUBS" "$LOG"; }
trap cleanup EXIT

if ! command -v unshare >/dev/null 2>&1; then
    echo "SKIP: unshare not available" >&2
    exit 77
fi
if [ ! -d "$APP" ] && [ "$MODE" != wrapper ]; then
    echo "SKIP: APP_DIR=$APP not found" >&2
    exit 77
fi

# ---- fake init commands -----------------------------------------------------
mkdir -p "$STUBS/common" "$STUBS/$INIT"
for n in pkill dbus-send; do
    printf '#!/bin/sh\necho "%s $*" >> "$SANDBOX_LOG/calls.log"\nexit 0\n' "$n" \
        > "$STUBS/common/$n"
    chmod +x "$STUBS/common/$n"
done
for n in systemctl rc-update rc-service sv dinitctl; do
    case "$n:$INIT" in
        systemctl:systemd|rc-update:openrc|rc-service:openrc|sv:runit|dinitctl:dinit)
            printf '#!/bin/sh\necho "%s $*" >> "$SANDBOX_LOG/calls.log"\nexit 0\n' "$n" \
                > "$STUBS/$INIT/$n"
            chmod +x "$STUBS/$INIT/$n"
            ;;
    esac
done

unshare -r -m -p -f --mount-proc --propagation private \
    env INIT="$INIT" MODE="$MODE" PROJ="$PROJ" APP="$APP" LOG="$LOG" \
        STUBS="$STUBS" START="${START:-0}" \
    bash -s <<'EOS'
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok: %s\n' "$*"; }
have() { [ -e "$1" ] || fail "missing $1"; ok "$1"; }

# ---- isolated system dirs ---------------------------------------------------
for d in /etc /usr/local /usr/share /var /run; do
    mount -t tmpfs tmpfs "$d"
done
printf 'root:x:0:0:root:/root:/bin/sh\n' > /etc/passwd
printf 'root:x:0:\n' > /etc/group

case "$INIT" in
    systemd)   mkdir -p /run/systemd/system ;;
    openrc)    mkdir -p /etc/init.d ;;
    runit)     mkdir -p /etc/sv
               # Void: /var/service dangles until runit has booted.
               ln -s ../run/runit/runsvdir/current /var/service ;;
    s6)        mkdir -p /etc/s6/sv /etc/s6/adminsv/default/contents.d ;;
    dinit)     mkdir -p /etc/dinit.d ;;
    sysvinit)  mkdir -p /etc/init.d ;;
    slackware) mkdir -p /etc/rc.d
               echo "Slackware 15.0" > /etc/slackware-version
               printf '#!/bin/sh\n' > /etc/rc.d/rc.local
               chmod +x /etc/rc.d/rc.local ;;
    *)         fail "unknown init $INIT" ;;
esac

export PATH="$STUBS/common:$STUBS/$INIT:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export SANDBOX_LOG="$LOG"

# shellcheck disable=SC1091
. "$PROJ/lib/common.sh"
[ "$(detect_init)" = "$INIT" ] || fail "detect_init said $(detect_init), expected $INIT"
ok "detect_init -> $INIT"

# ---- wrapper / Wayland logic ------------------------------------------------
if [ "$MODE" = wrapper ]; then
    W=/tmp/wapp
    mkdir -p "$W/bin" "$W/plugins/platforms"
    printf '#!/bin/sh\nexit 0\n' > "$W/bin/AmneziaVPN-service"
    printf '#!/bin/sh\necho "QT_QPA_PLATFORM=${QT_QPA_PLATFORM-<unset>} ARGS=$*"\n' \
        > "$W/bin/AmneziaVPN"
    chmod +x "$W/bin/AmneziaVPN-service" "$W/bin/AmneziaVPN"

    wrap_install() { "$PROJ/install.sh" --app-dir "$W" --no-start "$@"; }

    check_wrapper() {
        local want="$1" got; shift
        got="$("$@" /usr/local/bin/AmneziaVPN --foo)"
        case "$got" in
            "QT_QPA_PLATFORM=$want ARGS=--foo") ok "wrapper -> $want" ;;
            *) fail "wrapper expected $want, got: $got" ;;
        esac
    }

    wrap_install >/dev/null
    check_wrapper "<unset>" env -u QT_QPA_PLATFORM -u XDG_SESSION_TYPE
    check_wrapper "<unset>" env -u QT_QPA_PLATFORM XDG_SESSION_TYPE=x11
    check_wrapper xcb         env -u QT_QPA_PLATFORM XDG_SESSION_TYPE=wayland
    check_wrapper wayland     env QT_QPA_PLATFORM=wayland XDG_SESSION_TYPE=wayland

    wrap_install --force-x11 >/dev/null
    check_wrapper xcb env -u QT_QPA_PLATFORM XDG_SESSION_TYPE=x11
    check_wrapper xcb env -u QT_QPA_PLATFORM -u XDG_SESSION_TYPE

    touch "$W/plugins/platforms/libqwayland-egl.so"
    wrap_install >/dev/null
    check_wrapper "<unset>" env -u QT_QPA_PLATFORM XDG_SESSION_TYPE=wayland

    printf 'PASS: wrapper\n'
    exit 0
fi

start_args=()
[ "$START" = 1 ] && start_args=() || start_args=(--no-start)

run_install() {
    "$PROJ/install.sh" --app-dir "$APP" "${start_args[@]}"
}

run_uninstall() {
    "$PROJ/uninstall.sh" --app-dir "$APP"
}

assert_service() {
    case "$INIT" in
        systemd)
            have /etc/systemd/system/amneziavpn.service
            grep -q "ExecStart=$APP" /etc/systemd/system/amneziavpn.service \
                || fail "systemd unit has wrong ExecStart"
            grep -q "systemctl enable amneziavpn" "$LOG/calls.log" \
                || fail "systemctl enable not called"
            ;;
        openrc)
            have /etc/init.d/amneziavpn
            [ -x /etc/init.d/amneziavpn ] || fail "openrc script not executable"
            grep -q "command=\"$APP" /etc/init.d/amneziavpn \
                || fail "openrc command wrong"
            grep -q "rc-update add amneziavpn default" "$LOG/calls.log" \
                || fail "rc-update add not called"
            ;;
        runit)
            have /etc/sv/amneziavpn/run
            have /etc/sv/amneziavpn/finish
            have /etc/sv/amneziavpn/log/run
            [ -L /var/service/amneziavpn ] || fail "runit service not linked"
            [ -d /run/runit/runsvdir/current ] \
                || fail "dangling /var/service target was not created"
            grep -q "exec \"$APP" /etc/sv/amneziavpn/run \
                || fail "runit run script wrong"
            ;;
        s6)
            have /etc/s6/sv/amneziavpn/type
            have /etc/s6/sv/amneziavpn/run
            have /etc/s6/sv/amneziavpn/finish
            have /etc/s6/adminsv/default/contents.d/amneziavpn
            ;;
        dinit)
            have /etc/dinit.d/amneziavpn
            grep -q "command = \"$APP" /etc/dinit.d/amneziavpn \
                || fail "dinit command wrong"
            ;;
        sysvinit)
            have /etc/init.d/amneziavpn
            grep -q "DAEMON=\"$APP" /etc/init.d/amneziavpn \
                || fail "sysvinit daemon wrong"
            ;;
        slackware)
            have /etc/rc.d/rc.amneziavpn
            grep -q "rc.amneziavpn start" /etc/rc.d/rc.local \
                || fail "slackware rc.local not updated"
            ;;
    esac
}

assert_common() {
    have /usr/local/bin/AmneziaVPN
    [ -x /usr/local/bin/AmneziaVPN ] || fail "wrapper not executable"
    grep -q "^APP_DIR=\"$APP\"" /usr/local/bin/AmneziaVPN \
        || fail "wrapper has wrong APP_DIR"
    have /usr/share/applications/AmneziaVPN.desktop
    grep -q "^Exec=/usr/local/bin/AmneziaVPN$" /usr/share/applications/AmneziaVPN.desktop \
        || fail "desktop entry Exec wrong"
    have /usr/local/lib/amneziavpn/amnezia-dns-bridge
    have /etc/dbus-1/system.d/org.freedesktop.resolve1.conf
    [ -d /var/log/AmneziaVPN ] || fail "log dir missing"
    [ -d /var/lib/amneziavpn ] || fail "state dir missing"
    # Bridge service must exist for the selected init.
    case "$INIT" in
        systemd)   have /etc/systemd/system/amnezia-dns-bridge.service ;;
        openrc)    have /etc/init.d/amnezia-dns-bridge ;;
        runit)     have /etc/sv/amnezia-dns-bridge/run ;;
        s6)        have /etc/s6/sv/amnezia-dns-bridge/run ;;
        dinit)     have /etc/dinit.d/amnezia-dns-bridge ;;
        sysvinit)  have /etc/init.d/amnezia-dns-bridge ;;
        slackware) have /etc/rc.d/rc.amnezia-dns-bridge ;;
    esac
}

assert_uninstalled() {
    [ ! -e /usr/local/bin/AmneziaVPN ] || fail "wrapper not removed"
    [ ! -e /usr/share/applications/AmneziaVPN.desktop ] || fail "desktop entry not removed"
    [ ! -e /usr/local/lib/amneziavpn/amnezia-dns-bridge ] || fail "bridge not removed"
    [ ! -e /etc/dbus-1/system.d/org.freedesktop.resolve1.conf ] || fail "dbus policy not removed"
    case "$INIT" in
        systemd)   [ ! -e /etc/systemd/system/amneziavpn.service ] || fail "unit not removed"
                   [ ! -e /etc/systemd/system/amnezia-dns-bridge.service ] || fail "bridge unit not removed" ;;
        openrc)    [ ! -e /etc/init.d/amneziavpn ] || fail "init script not removed" ;;
        runit)     [ ! -e /etc/sv/amneziavpn ] || fail "sv dir not removed"
                   [ ! -e /var/service/amneziavpn ] || fail "service link not removed" ;;
        s6)        [ ! -e /etc/s6/sv/amneziavpn ] || fail "s6 service not removed" ;;
        dinit)     [ ! -e /etc/dinit.d/amneziavpn ] || fail "dinit service not removed" ;;
        sysvinit)  [ ! -e /etc/init.d/amneziavpn ] || fail "init script not removed" ;;
        slackware) [ ! -e /etc/rc.d/rc.amneziavpn ] || fail "rc script not removed"
                   ! grep -q "rc.amneziavpn start" /etc/rc.d/rc.local || fail "rc.local not cleaned" ;;
    esac
    [ -d /var/log/AmneziaVPN ] || fail "log dir should survive uninstall"
    [ ! -d /var/lib/amneziavpn ] || fail "state dir should be removed"
}

assert_started() {
    [ "$START" = 1 ] || return 0
    case "$INIT" in
        systemd)  grep -q "systemctl restart amneziavpn" "$LOG/calls.log" \
                      || fail "service was not started (systemd)" ;;
        openrc)   grep -q "rc-service amneziavpn restart" "$LOG/calls.log" \
                      || fail "service was not started (openrc)" ;;
        runit)    grep -q "sv restart amneziavpn" "$LOG/calls.log" \
                      || fail "service was not started (runit)" ;;
        dinit)    grep -q "dinitctl start amneziavpn" "$LOG/calls.log" \
                      || fail "service was not started (dinit)" ;;
        sysvinit|slackware)
                  [ -f /run/amneziavpn.pid ] || fail "pidfile missing"
                  kill -0 "$(cat /run/amneziavpn.pid)" 2>/dev/null \
                      || fail "service process is not running" ;;
    esac
    ok "service started"
}

seed_stale_unit() {
    mkdir -p /etc/systemd/system
    printf '[Unit]\nDescription=stale official unit\n' \
        > /etc/systemd/system/AmneziaVPN.service
}

assert_stale_unit_gone() {
    [ ! -e /etc/systemd/system/AmneziaVPN.service ] \
        || fail "stale official unit was not removed"
    if [ "$INIT" != systemd ]; then
        ! grep -q '^systemctl' "$LOG/calls.log" \
            || fail "systemctl was called on a non-systemd host"
    fi
    ok "stale official unit removed"
}

case "$MODE" in
    install)
        seed_stale_unit
        run_install
        assert_service
        assert_common
        assert_started
        assert_stale_unit_gone
        ;;
    twice)
        seed_stale_unit
        run_install
        run_install
        assert_service
        assert_common
        assert_started
        assert_stale_unit_gone
        ;;
    uninstall)
        seed_stale_unit
        run_install
        seed_stale_unit
        run_uninstall
        assert_uninstalled
        assert_stale_unit_gone
        ;;
    both)
        seed_stale_unit
        run_install
        assert_service
        assert_common
        assert_started
        seed_stale_unit
        run_uninstall
        assert_uninstalled
        assert_stale_unit_gone
        ;;
    *) fail "unknown mode $MODE" ;;
esac

printf 'PASS: %s (%s)\n' "$INIT" "$MODE"
EOS
