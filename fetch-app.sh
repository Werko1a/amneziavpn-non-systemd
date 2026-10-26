#!/usr/bin/env bash
# Extract the official AmneziaVPN .run installer into /opt/AmneziaVPN
# WITHOUT running its systemd-only post_install.sh.
#
# Usage:
#   sudo ./fetch-app.sh --run ~/Downloads/AmneziaVPN_5.0.3.0_linux_x64.run
#   sudo ./fetch-app.sh --version 5.0.3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

RUN_FILE=""
VERSION=""
APP_DIR="$DEFAULT_APP_DIR"

usage() {
    cat <<EOF
Usage: sudo $0 (--run FILE | --version VER) [--app-dir DIR]

  --run FILE       уже скачанный AmneziaVPN_*_linux_x64.run
  --version VER    скачать с GitHub releases (например 5.0.3.0)
  --app-dir DIR    куда распаковать (по умолчанию $DEFAULT_APP_DIR)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --run)     RUN_FILE="${2:?}"; shift 2 ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --app-dir) APP_DIR="${2:?}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "неизвестный аргумент: $1" ;;
    esac
done

need_root "$@"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -z "$RUN_FILE" ]; then
    [ -n "$VERSION" ] || die "укажи --run FILE или --version VER"
    RUN_FILE="$WORK/AmneziaVPN_${VERSION}_linux_x64.run"
    log "скачиваю AmneziaVPN ${VERSION}"
    curl -fL --retry 3 -o "$RUN_FILE" \
        "https://github.com/amnezia-vpn/amnezia-client/releases/download/${VERSION}/AmneziaVPN_${VERSION}_linux_x64.run"
fi

[ -f "$RUN_FILE" ] || die "файл не найден: $RUN_FILE"

EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"

extract_with_7z() {
    local bin off tmp found=0
    bin="$(command -v 7z || command -v 7za || true)"
    [ -n "$bin" ] || return 1

    # Qt Installer Framework appends several independent 7z archives to the
    # ELF installer.  Scan for the 7z signature, keep only the real archives
    # (the file may contain look-alike bytes inside compressed resources) and
    # merge them into one tree.
    while IFS=: read -r off _; do
        [ -n "$off" ] || continue
        tmp="$WORK/candidate-$off.7z"
        tail -c "+$((off + 1))" "$RUN_FILE" > "$tmp"
        # Do not pipe into grep -q: with `pipefail` 7z would get SIGPIPE and
        # the whole pipeline would look like a failure.
        "$bin" l "$tmp" </dev/null >"$WORK/listing.txt" 2>/dev/null || true
        if grep -q '^Type = 7z' "$WORK/listing.txt"; then
            log "  payload @ $off"
            "$bin" x -y -o"$EXTRACT" "$tmp" </dev/null >/dev/null 2>&1 || true
            found=1
        fi
        rm -f "$tmp"
    done < <(LC_ALL=C grep -abo $'7z\xbc\xaf\x27\x1c' "$RUN_FILE" || true)

    [ "$found" = 1 ]
}

extract_with_bsdtar() {
    command -v bsdtar >/dev/null 2>&1 || return 1
    bsdtar -xf "$RUN_FILE" -C "$EXTRACT" >/dev/null 2>&1
}

extract_with_binwalk() {
    command -v binwalk >/dev/null 2>&1 || return 1
    ( cd "$WORK" && binwalk -qe -y=7zip "$RUN_FILE" >/dev/null 2>&1 ) || return 1
    local src
    src="$(find "$WORK" -type d -name '*.extracted' -print -quit 2>/dev/null || true)"
    [ -n "$src" ] || return 1
    # Flatten the binwalk output into $EXTRACT.
    find "$src" -mindepth 1 -maxdepth 3 -type d -print0 2>/dev/null \
        | while IFS= read -r -d '' d; do
            if [ -e "$d/bin" ] || [ -e "$d/plugins" ] || [ -e "$d/lib" ]; then
                cp -a "$d/." "$EXTRACT/"
                break
            fi
        done
}

if ! extract_with_7z && ! extract_with_bsdtar && ! extract_with_binwalk; then
    die "не удалось распаковать .run. Установи p7zip (7z) или binwalk и повтори."
fi

# Find the directory that looks like the application root.
APP_ROOT=""
for marker in plugins lib/bin bin/AmneziaVPN AmneziaVPN; do
    candidate="$(find "$EXTRACT" -maxdepth 5 -path "*/$marker" -print -quit 2>/dev/null || true)"
    [ -n "$candidate" ] || continue
    case "$marker" in
        plugins|lib) APP_ROOT="$(dirname "$candidate")" ;;
        bin/AmneziaVPN) APP_ROOT="$(dirname "$(dirname "$candidate")")" ;;
        AmneziaVPN) APP_ROOT="$(dirname "$candidate")" ;;
    esac
    [ -d "$APP_ROOT" ] && break
done

if [ -z "$APP_ROOT" ]; then
    # Last resort: the directory containing the helper binary.
    helper="$(find "$EXTRACT" -type f -name 'AmneziaVPN-service' -perm -u+x -print -quit 2>/dev/null || true)"
    [ -n "$helper" ] || die "распаковалось, но не похоже на AmneziaVPN"
    APP_ROOT="$(dirname "$helper")"
    [ "$(basename "$APP_ROOT")" = "bin" ] && APP_ROOT="$(dirname "$APP_ROOT")"
fi

log "application root: $APP_ROOT"

install -d -m 0755 "$APP_DIR"
cp -a "$APP_ROOT/." "$APP_DIR/"

# The official tree may put the helper in bin/ or in a service/ subdirectory.
if ! find_service_binary "$APP_DIR" >/dev/null 2>&1; then
    die "в $APP_DIR не найден AmneziaVPN-service — проверь содержимое"
fi

log "распаковано в $APP_DIR"
log "теперь запусти: sudo $SCRIPT_DIR/install.sh --app-dir $APP_DIR"
