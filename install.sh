#!/usr/bin/env bash
# amneziavpn-universal installer
#
# Installs the privileged AmneziaVPN helper under the init system that is
# actually running (OpenRC, runit, s6, dinit, SysVinit, Slackware, systemd)
# and, when systemd-resolved is absent, a small D-Bus DNS bridge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

APP_DIR="$DEFAULT_APP_DIR"
BRIDGE_MODE="auto"   # auto | yes | no
FORCE_X11="auto"     # auto | yes | no
DO_START=1
CHECK_ONLY=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --app-dir DIR        где лежит распакованный AmneziaVPN (по умолчанию $DEFAULT_APP_DIR)
  --with-dns-bridge    поставить DNS-мост даже если systemd-resolved найден
  --no-dns-bridge      не ставить DNS-мост (DNS придётся настроить вручную)
  --force-x11          всегда запускать GUI через XWayland (QT_QPA_PLATFORM=xcb)
  --no-force-x11       не трогать QT_QPA_PLATFORM
  --no-start           установить сервисы, но не запускать их
  --check              только показать, что будет сделано (без изменений)
  -h, --help           эта справка

Примеры:
  sudo $0 --app-dir /opt/AmneziaVPN
  sudo $0 --force-x11
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app-dir)        APP_DIR="${2:?}"; shift 2 ;;
        --with-dns-bridge) BRIDGE_MODE="yes"; shift ;;
        --no-dns-bridge)  BRIDGE_MODE="no"; shift ;;
        --force-x11)      FORCE_X11="yes"; shift ;;
        --no-force-x11)   FORCE_X11="no"; shift ;;
        --no-start)       DO_START=0; shift ;;
        --check)          CHECK_ONLY=1; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Service plumbing
# ---------------------------------------------------------------------------

SVC_NAME=""
SVC_DESC=""
SVC_BIN=""
SVC_ARGS=""
SVC_OPENRC_DEPS=""
SVC_DINIT_DEPS=""
SVC_SYSTEMD_AFTER=""
SVC_SYSTEMD_WANTS=""

render_service() {
    local tpl="$1" out="$2"
    render_template "$tpl" "$out" \
        "NAME=$SVC_NAME" \
        "DESC=$SVC_DESC" \
        "BIN=$SVC_BIN" \
        "ARGS=$SVC_ARGS" \
        "LOGDIR=$LOG_DIR" \
        "RUNDIR=/run" \
        "OPENRC_DEPS=$SVC_OPENRC_DEPS" \
        "DINIT_DEPS=$SVC_DINIT_DEPS" \
        "SYSTEMD_AFTER=$SVC_SYSTEMD_AFTER" \
        "SYSTEMD_WANTS=$SVC_SYSTEMD_WANTS"
}

install_service() {
    local tmp
    tmp="$(mktemp -d "$WORK_DIR/svc.XXXXXX")"

    case "$INIT" in
    systemd)
        render_service "$SCRIPT_DIR/init/systemd/service.template" "$tmp/unit"
        install -D -m 0644 "$tmp/unit" "/etc/systemd/system/${SVC_NAME}.service"
        systemctl daemon-reload
        systemctl enable "$SVC_NAME" >/dev/null 2>&1 || true
        if [ "$DO_START" = 1 ]; then
            systemctl restart "$SVC_NAME" \
                || warn "не удалось запустить $SVC_NAME (journalctl -u $SVC_NAME)"
        fi
        ;;
    openrc)
        render_service "$SCRIPT_DIR/init/openrc/service.template" "$tmp/initd"
        install -D -m 0755 "$tmp/initd" "/etc/init.d/${SVC_NAME}"
        rc-update add "$SVC_NAME" default >/dev/null 2>&1 || true
        if [ "$DO_START" = 1 ]; then
            if rc-service "$SVC_NAME" status >/dev/null 2>&1; then
                rc-service "$SVC_NAME" restart \
                    || warn "не удалось перезапустить $SVC_NAME (rc-service $SVC_NAME status)"
            else
                rc-service "$SVC_NAME" start \
                    || warn "не удалось запустить $SVC_NAME (rc-service $SVC_NAME status)"
            fi
        fi
        ;;
    runit)
        install -d -m 0755 "/etc/sv/${SVC_NAME}/log"
        render_service "$SCRIPT_DIR/init/runit/run.template" "$tmp/run"
        render_service "$SCRIPT_DIR/init/runit/finish.template" "$tmp/finish"
        render_service "$SCRIPT_DIR/init/runit/log-run.template" "$tmp/log-run"
        install -m 0755 "$tmp/run" "/etc/sv/${SVC_NAME}/run"
        install -m 0755 "$tmp/finish" "/etc/sv/${SVC_NAME}/finish"
        install -m 0755 "$tmp/log-run" "/etc/sv/${SVC_NAME}/log/run"
        svdir="$(runit_service_dir)"
        # On Void /var/service is a symlink to /run/runit/runsvdir/current,
        # which does not exist until runit has booted.  Materialise the target
        # so the symlink (and this install) is valid even before a reboot.
        if [ -L "$svdir" ] && [ ! -d "$svdir" ]; then
            svtarget="$(readlink "$svdir")"
            case "$svtarget" in
                /*) ;;
                *) svtarget="$(dirname "$svdir")/$svtarget" ;;
            esac
            install -d -m 0755 "$svtarget"
        fi
        install -d -m 0755 "$svdir"
        ln -sfn "/etc/sv/${SVC_NAME}" "$svdir/${SVC_NAME}"
        if [ "$DO_START" = 1 ]; then
            # runsvdir rescans its directory periodically.  Retry until it has
            # picked up the new service instead of printing a scary warning.
            i=0
            while [ "$i" -lt 8 ]; do
                if SVDIR="$svdir" sv restart "$SVC_NAME" 2>/dev/null \
                    || SVDIR="$svdir" sv up "$SVC_NAME" 2>/dev/null; then
                    break
                fi
                sleep 1
                i=$((i + 1))
            done
        fi
        ;;
    s6)
        install -d -m 0755 "/etc/s6/sv/${SVC_NAME}"
        render_service "$SCRIPT_DIR/init/s6/type.template" "$tmp/type"
        render_service "$SCRIPT_DIR/init/s6/run.template" "$tmp/run"
        render_service "$SCRIPT_DIR/init/s6/finish.template" "$tmp/finish"
        install -m 0644 "$tmp/type" "/etc/s6/sv/${SVC_NAME}/type"
        install -m 0755 "$tmp/run" "/etc/s6/sv/${SVC_NAME}/run"
        install -m 0755 "$tmp/finish" "/etc/s6/sv/${SVC_NAME}/finish"
        if [ -d /etc/s6/adminsv/default/contents.d ]; then
            touch "/etc/s6/adminsv/default/contents.d/${SVC_NAME}"
            if command -v s6-rc-compile >/dev/null 2>&1 && [ -d /etc/s6/rc ]; then
                s6-rc-compile /etc/s6/rc/compiled /etc/s6/sv 2>/dev/null || true
                s6-rc-update /etc/s6/rc/compiled 2>/dev/null || true
            fi
        else
            warn "s6: добавь ${SVC_NAME} в свой bundle вручную (см. docs/s6.md)"
        fi
        ;;
    dinit)
        render_service "$SCRIPT_DIR/init/dinit/service.template" "$tmp/dinit"
        install -D -m 0644 "$tmp/dinit" "/etc/dinit.d/${SVC_NAME}"
        if [ "$DO_START" = 1 ]; then
            dinitctl enable "$SVC_NAME" >/dev/null 2>&1 || true
            dinitctl start "$SVC_NAME" 2>/dev/null || dinitctl restart "$SVC_NAME" 2>/dev/null || true
        fi
        ;;
    sysvinit)
        render_service "$SCRIPT_DIR/init/sysvinit/service.template" "$tmp/initd"
        install -D -m 0755 "$tmp/initd" "/etc/init.d/${SVC_NAME}"
        if command -v update-rc.d >/dev/null 2>&1; then
            update-rc.d "$SVC_NAME" defaults >/dev/null 2>&1 || true
        fi
        if [ "$DO_START" = 1 ]; then
            "/etc/init.d/${SVC_NAME}" restart \
                || warn "не удалось запустить $SVC_NAME (см. $LOG_DIR/${SVC_NAME}.out)"
        fi
        ;;
    slackware)
        render_service "$SCRIPT_DIR/init/sysvinit/service.template" "$tmp/initd"
        install -D -m 0755 "$tmp/initd" "/etc/rc.d/rc.${SVC_NAME}"
        if [ -f /etc/rc.d/rc.local ] && ! grep -q "rc\.${SVC_NAME} start" /etc/rc.d/rc.local; then
            {
                printf '\n# AmneziaVPN\n'
                printf '[ -x /etc/rc.d/rc.%s ] && /etc/rc.d/rc.%s start\n' "$SVC_NAME" "$SVC_NAME"
            } >> /etc/rc.d/rc.local
        fi
        if [ "$DO_START" = 1 ]; then
            "/etc/rc.d/rc.${SVC_NAME}" restart \
                || warn "не удалось запустить $SVC_NAME (см. $LOG_DIR/${SVC_NAME}.out)"
        fi
        ;;
    *)
        install -d -m 0755 "$STATE_DIR/init"
        render_service "$SCRIPT_DIR/init/sysvinit/service.template" "$STATE_DIR/init/${SVC_NAME}"
        warn "неизвестная init-система. Скрипт положен в $STATE_DIR/init/${SVC_NAME}"
        warn "запусти его вручную или добавь в свой супервизор"
        ;;
    esac
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Desktop integration
# ---------------------------------------------------------------------------

install_client_wrapper() {
    local client_bin="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
#!/bin/sh
# Generated by amneziavpn-universal. Override QT_QPA_PLATFORM yourself if needed.
APP_DIR="$APP_DIR"
CLIENT="$client_bin"
X11_MODE="$FORCE_X11"

has_wayland_plugin() {
    for dir in "\$APP_DIR/plugins/platforms" "\$APP_DIR/lib/plugins/platforms" "\$APP_DIR/plugins"; do
        for plugin in "\$dir"/libqwayland*; do
            [ -e "\$plugin" ] && return 0
        done
    done
    return 1
}

if [ -z "\${QT_QPA_PLATFORM:-}" ]; then
    if [ "\$X11_MODE" = "yes" ]; then
        export QT_QPA_PLATFORM=xcb
    elif [ "\$X11_MODE" = "auto" ] && [ "\${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        has_wayland_plugin || export QT_QPA_PLATFORM=xcb
    fi
fi

exec "\$CLIENT" "\$@"
EOF
    install -D -m 0755 "$tmp" /usr/local/bin/AmneziaVPN
    rm -f "$tmp"
}

install_desktop_entry() {
    local icon=""
    for candidate in \
        "$APP_DIR/AmneziaVPN.png" \
        "$APP_DIR/AmneziaVPN.svg" \
        "$APP_DIR/icon.png" \
        "$APP_DIR/bin/AmneziaVPN.png" \
        "$SCRIPT_DIR/assets/AmneziaVPN.png"; do
        [ -f "$candidate" ] && { icon="$candidate"; break; }
    done

    if [ -n "$icon" ]; then
        case "$icon" in
            *.svg)
                install -D -m 0644 "$icon" /usr/share/icons/hicolor/scalable/apps/AmneziaVPN.svg
                ;;
            *)
                install -D -m 0644 "$icon" /usr/share/icons/hicolor/512x512/apps/AmneziaVPN.png
                install -D -m 0644 "$icon" /usr/share/pixmaps/AmneziaVPN.png
                ;;
        esac
    fi

    install -d -m 0755 /usr/share/applications
    cat > /usr/share/applications/AmneziaVPN.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=AmneziaVPN
Comment=Amnezia VPN client
Exec=/usr/local/bin/AmneziaVPN
Icon=AmneziaVPN
Terminal=false
Categories=Network;VPN;Security;
StartupWMClass=AmneziaVPN
EOF
    chmod 0644 /usr/share/applications/AmneziaVPN.desktop
}

# ---------------------------------------------------------------------------
# DNS bridge
# ---------------------------------------------------------------------------

should_install_bridge() {
    case "$BRIDGE_MODE" in
        no)  return 1 ;;
        yes) return 0 ;;
        auto)
            if has_systemd_resolved; then
                log "systemd-resolved найден — DNS-мост не нужен"
                return 1
            fi
            return 0
            ;;
    esac
}

install_bridge() {
    if ! bridge_python_ok; then
        if [ "$BRIDGE_MODE" = "yes" ]; then
            print_bridge_deps_help
            die "не хватает зависимостей для DNS-моста"
        fi
        warn "python3-dbus / PyGObject не найдены — DNS-мост пропущен"
        print_bridge_deps_help
        warn "VPN подключится, но DNS внутри туннеля, скорее всего, не заработает"
        return 0
    fi

    install -D -m 0755 "$SCRIPT_DIR/dns/amnezia-dns-bridge.py" "$LIB_DIR/amnezia-dns-bridge"
    install -D -m 0644 "$SCRIPT_DIR/dns/org.freedesktop.resolve1.conf" \
        /etc/dbus-1/system.d/org.freedesktop.resolve1.conf

    # Make the system bus pick up the new policy without a reboot.
    if command -v dbus-send >/dev/null 2>&1; then
        dbus-send --system --type=method_call --dest=org.freedesktop.DBus \
            / org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1 || true
    fi

    SVC_NAME="$BRIDGE_NAME"
    SVC_DESC="D-Bus DNS bridge for AmneziaVPN (org.freedesktop.resolve1 shim)"
    SVC_BIN="$LIB_DIR/amnezia-dns-bridge"
    SVC_ARGS=""
    SVC_OPENRC_DEPS="need dbus"
    SVC_DINIT_DEPS=""
    SVC_SYSTEMD_AFTER="After=dbus.service"
    SVC_SYSTEMD_WANTS="Wants=dbus.service"
    install_service
    log "DNS-мост установлен"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = 0 ]; then
    need_root "$@"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

INIT="$(detect_init)"
log "init system: $INIT"

[ -d "$APP_DIR" ] || die "не найден каталог $APP_DIR.
Распакуй официальный .run туда (см. README) или укажи --app-dir."

SERVICE_BIN="$(find_service_binary "$APP_DIR")" \
    || die "в $APP_DIR не найден исполняемый AmneziaVPN-service"
CLIENT_BIN="$(find_client_binary "$APP_DIR" || true)"
log "service: $SERVICE_BIN"
[ -n "$CLIENT_BIN" ] && log "client:  $CLIENT_BIN"

if [ "$CHECK_ONLY" = 1 ]; then
    if has_systemd_resolved; then
        log "systemd-resolved: есть (DNS-мост не нужен)"
    else
        log "systemd-resolved: нет (нужен DNS-мост)"
        if bridge_python_ok; then
            log "python3-dbus/PyGObject: ok"
        else
            warn "python3-dbus/PyGObject: отсутствуют (мост не поставится)"
        fi
    fi
    if [ -n "$CLIENT_BIN" ]; then
        if [ "$FORCE_X11" = "yes" ]; then
            log "GUI: принудительно XWayland"
        elif has_wayland_plugin "$APP_DIR"; then
            log "GUI: Wayland-плагин найден"
        else
            log "GUI: Wayland-плагина нет, будет XWayland при Wayland-сессии"
        fi
    fi
    log "check mode: изменения не вносились"
    exit 0
fi

install -d -m 0755 "$LOG_DIR" "$STATE_DIR" "$LIB_DIR"

# The official installer drops AmneziaVPN.service into /etc/systemd/system.
# Remove it so it cannot race with our service (and cannot break non-systemd).
if [ -f /etc/systemd/system/AmneziaVPN.service ]; then
    if [ "$INIT" = "systemd" ]; then
        systemctl disable --now AmneziaVPN >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/AmneziaVPN.service
    [ "$INIT" = "systemd" ] && systemctl daemon-reload
    log "удалён старый юнит /etc/systemd/system/AmneziaVPN.service"
fi

# Stop a manually started helper so the new service can own the sockets.
pkill -f 'bin/AmneziaVPN-service' 2>/dev/null || true
pkill -f 'AmneziaVPN-service$' 2>/dev/null || true
sleep 1

SVC_NAME="$SERVICE_NAME"
SVC_DESC="AmneziaVPN privileged service"
SVC_BIN="$SERVICE_BIN"
SVC_ARGS=""
SVC_OPENRC_DEPS="need net; use dbus"
SVC_DINIT_DEPS=""
SVC_SYSTEMD_AFTER="After=network.target dbus.service"
SVC_SYSTEMD_WANTS="Wants=dbus.service"
install_service

if should_install_bridge; then
    install_bridge
fi

if [ -n "$CLIENT_BIN" ]; then
    install_client_wrapper "$CLIENT_BIN"
    install_desktop_entry
fi

log "готово"
cat <<EOF

Проверить:
  init=$INIT
  sudo rc-service ${SERVICE_NAME} status   # OpenRC
  sudo sv status ${SERVICE_NAME}           # runit
  sudo systemctl status ${SERVICE_NAME}    # systemd
  sudo dinitctl status ${SERVICE_NAME}     # dinit
  tail -f ${LOG_DIR}/AmneziaVPN-service.log

Запуск GUI: AmneziaVPN (или /usr/local/bin/AmneziaVPN)
EOF
