#!/usr/bin/env bash
# amneziavpn-universal uninstaller
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

APP_DIR="$DEFAULT_APP_DIR"
PURGE=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --app-dir DIR   где установлен AmneziaVPN (по умолчанию $DEFAULT_APP_DIR)
  --purge         также удалить $APP_DIR, логи и состояние
  -h, --help      эта справка
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app-dir) APP_DIR="${2:?}"; shift 2 ;;
        --purge)   PURGE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

need_root "$@"
INIT="$(detect_init)"
log "init system: $INIT"

remove_service() {
    local name="$1"
    case "$INIT" in
    systemd)
        systemctl disable --now "$name" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${name}.service"
        systemctl daemon-reload 2>/dev/null || true
        ;;
    openrc)
        rc-service "$name" stop >/dev/null 2>&1 || true
        rc-update del "$name" default >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${name}"
        ;;
    runit)
        SVDIR="$(runit_service_dir)" sv down "$name" >/dev/null 2>&1 || true
        rm -f "$(runit_service_dir)/${name}"
        rm -rf "/etc/sv/${name}"
        ;;
    s6)
        rm -rf "/etc/s6/sv/${name}"
        rm -f "/etc/s6/adminsv/default/contents.d/${name}"
        if command -v s6-rc-compile >/dev/null 2>&1 && [ -d /etc/s6/rc ]; then
            s6-rc-compile /etc/s6/rc/compiled /etc/s6/sv >/dev/null 2>&1 || true
            s6-rc-update /etc/s6/rc/compiled >/dev/null 2>&1 || true
        fi
        ;;
    dinit)
        dinitctl stop "$name" >/dev/null 2>&1 || true
        dinitctl disable "$name" >/dev/null 2>&1 || true
        rm -f "/etc/dinit.d/${name}"
        ;;
    sysvinit)
        "/etc/init.d/${name}" stop >/dev/null 2>&1 || true
        update-rc.d -f "$name" remove >/dev/null 2>&1 || true
        rm -f "/etc/init.d/${name}"
        ;;
    slackware)
        "/etc/rc.d/rc.${name}" stop >/dev/null 2>&1 || true
        rm -f "/etc/rc.d/rc.${name}"
        if [ -f /etc/rc.d/rc.local ]; then
            sed -i "\|rc\.${name} start|d" /etc/rc.d/rc.local || true
        fi
        ;;
    esac
}

restore_resolv_conf() {
    if command -v resolvconf >/dev/null 2>&1; then
        resolvconf -d amneziavpn >/dev/null 2>&1 || true
    fi

    [ -f "$STATE_DIR/resolv.conf.meta" ] || return 0
    local kind
    kind="$(cat "$STATE_DIR/resolv.conf.meta")"

    case "$kind" in
        symlink:*)
            local target="${kind#symlink:}"
            rm -f /etc/resolv.conf
            ln -s "$target" /etc/resolv.conf
            ;;
        *)
            [ -f "$STATE_DIR/resolv.conf.bak" ] && cp -f "$STATE_DIR/resolv.conf.bak" /etc/resolv.conf
            ;;
    esac
    rm -f "$STATE_DIR/resolv.conf.meta" "$STATE_DIR/resolv.conf.bak"
    log "восстановлен /etc/resolv.conf"
}

log "останавливаю сервисы"
remove_service "$BRIDGE_NAME"
remove_service "$SERVICE_NAME"

# Belt and braces: the official unit may still be lying around.
if [ -f /etc/systemd/system/AmneziaVPN.service ]; then
    if [ "$INIT" = "systemd" ]; then
        systemctl disable --now AmneziaVPN >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/AmneziaVPN.service
    if [ "$INIT" = "systemd" ]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
fi

pkill -f 'bin/AmneziaVPN-service' 2>/dev/null || true
pkill -f 'AmneziaVPN-service$' 2>/dev/null || true
pkill -f 'amnezia-dns-bridge' 2>/dev/null || true

restore_resolv_conf

log "удаляю файлы"
rm -f /usr/local/bin/AmneziaVPN
rm -f /usr/share/applications/AmneziaVPN.desktop
rm -f /usr/share/pixmaps/AmneziaVPN.png
rm -f /usr/share/icons/hicolor/512x512/apps/AmneziaVPN.png
rm -f /usr/share/icons/hicolor/scalable/apps/AmneziaVPN.svg
rm -f "$LIB_DIR/amnezia-dns-bridge"
rmdir "$LIB_DIR" 2>/dev/null || true
rm -f /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
        / org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
fi

if [ "$PURGE" = 1 ]; then
    log "purge: удаляю $APP_DIR и логи"
    rm -rf "$APP_DIR" "$LOG_DIR" "$STATE_DIR"
else
    rm -rf "$STATE_DIR"
    log "оставлены $APP_DIR и $LOG_DIR (убери через --purge)"
fi

log "готово"
