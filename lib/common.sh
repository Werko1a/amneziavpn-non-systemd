# shellcheck shell=bash
# shellcheck disable=SC2034
# Shared helpers for amneziavpn-universal.
# This file is sourced, so it must not change the caller's shell options.

APP_NAME="AmneziaVPN"
DEFAULT_APP_DIR="/opt/AmneziaVPN"
LIB_DIR="/usr/local/lib/amneziavpn"
STATE_DIR="/var/lib/amneziavpn"
LOG_DIR="/var/log/AmneziaVPN"
SERVICE_NAME="amneziavpn"
BRIDGE_NAME="amnezia-dns-bridge"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "Запусти от root: sudo $0 $*"
}

# Prints one of: systemd openrc runit s6 dinit sysvinit unknown
detect_init() {
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        echo systemd
    elif [ -f /etc/slackware-version ]; then
        echo slackware
    elif command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        echo openrc
    elif command -v sv >/dev/null 2>&1 && [ -d /etc/sv ]; then
        echo runit
    elif command -v dinitctl >/dev/null 2>&1; then
        echo dinit
    elif [ -d /etc/s6 ] || command -v s6-rc >/dev/null 2>&1; then
        echo s6
    elif [ -d /etc/init.d ]; then
        echo sysvinit
    else
        echo unknown
    fi
}

# Where runit expects enabled services (Void uses /var/service, Artix /etc/service).
runit_service_dir() {
    local d
    for d in /var/service /etc/service /run/runit/service; do
        [ -d "$d" ] && { echo "$d"; return; }
    done
    echo /var/service
}

# True when systemd-resolved answers on the system bus.
has_systemd_resolved() {
    [ -S /run/dbus/system_bus_socket ] || return 1
    if command -v busctl >/dev/null 2>&1; then
        busctl --system --no-pager status org.freedesktop.resolve1 >/dev/null 2>&1 && return 0
        return 1
    fi
    # No busctl (non-systemd host): ask the bus directly.
    if command -v dbus-send >/dev/null 2>&1; then
        local reply
        reply="$(dbus-send --system --print-reply --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
            string:org.freedesktop.resolve1 2>/dev/null || true)"
        case "$reply" in
            *"boolean true"*) return 0 ;;
        esac
    fi
    # Last resort: the resolved runtime directory is a strong hint.
    [ -d /run/systemd/resolve ] && return 0
    return 1
}

# Locate the privileged helper inside an extracted/installed tree.
find_service_binary() {
    local dir="$1" p
    for p in \
        "$dir/bin/AmneziaVPN-service" \
        "$dir/AmneziaVPN-service" \
        "$dir/service/bin/AmneziaVPN-service" \
        "$dir/service/AmneziaVPN-service" \
        "$dir/client/bin/AmneziaVPN-service"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    p="$(find "$dir" -maxdepth 4 -type f -name 'AmneziaVPN-service' -perm -u+x -print -quit 2>/dev/null)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

# Locate the GUI binary inside an extracted/installed tree.
find_client_binary() {
    local dir="$1" p
    for p in \
        "$dir/bin/AmneziaVPN" \
        "$dir/AmneziaVPN" \
        "$dir/client/bin/AmneziaVPN"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    p="$(find "$dir" -maxdepth 4 -type f -name 'AmneziaVPN' -perm -u+x -print -quit 2>/dev/null)"
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    return 1
}

# Escape a string so it can be used on the replacement side of s|...|...|.
_sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Render a service template. Usage: render_template <tpl> <out> [KEY=VALUE ...]
render_template() {
    local tpl="$1" out="$2"; shift 2
    local expr=() kv
    for kv in "$@"; do
        expr+=(-e "s|@${kv%%=*}@|$(_sed_escape "${kv#*=}")|g")
    done
    sed "${expr[@]}" "$tpl" > "$out"
}

# True when the bundled Qt ships a Wayland platform plugin.
has_wayland_plugin() {
    local dir="$1" f
    for f in \
        "$dir"/plugins/platforms/libqwayland* \
        "$dir"/lib/plugins/platforms/libqwayland* \
        "$dir"/plugins/libqwayland*; do
        [ -e "$f" ] && return 0
    done
    return 1
}

# Install the python DNS bridge files (used by install.sh and the native patch docs).
bridge_python_ok() {
    python3 - <<'PY' >/dev/null 2>&1
import dbus, dbus.service
from gi.repository import GLib
PY
}

print_bridge_deps_help() {
    cat >&2 <<'EOF'

DNS-мосту нужны python3 + dbus-python + PyGObject.
Установи их для своего дистрибутива:

  Gentoo:    sudo emerge --ask dev-python/dbus-python dev-python/pygobject
  Void:      sudo xbps-install -S python3-dbus python3-gobject
  Arch:      sudo pacman -S python-dbus python-gobject
  Alpine:    sudo apk add py3-dbus py3-gobject3
  Devuan:    sudo apt install python3-dbus python3-gi
  Slackware: см. docs/slackware.md (sbopkg: dbus-python, pygobject3)
  Fedora:    sudo dnf install python3-dbus python3-gobject

Либо запусти установку с --no-dns-bridge и настрой DNS вручную
(см. docs/dns.md), либо собери форк с нативным патчем (patches/).
EOF
}
