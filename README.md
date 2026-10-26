# amneziavpn-universal

Запуск официального клиента **AmneziaVPN** на Linux **без systemd** — Gentoo/OpenRC,
Void/runit, Artix, Alpine, Devuan, Slackware и любых других init-системах.

> Статус: **alpha**. Код установщика и сервисов готов, но на живых OpenRC/runit
> системах ещё не прогонялся. См. раздел «Тестирование».

---

## Зачем это нужно

В самом демоне AmneziaVPN (`AmneziaVPN-service`) **нет вызовов systemd**. Это
обычный Qt-процесс, который слушает unix-сокеты. systemd нужен только в трёх
местах:

| Что | Где | Как решаем |
|---|---|---|
| Запуск и перезапуск демона | `deploy/data/linux/AmneziaVPN.service`, `systemctl` в `post_install.sh` | свои init-скрипты + автодетект init |
| Настройка DNS | `client/platforms/linux/daemon/dnsutilslinux.cpp` — D-Bus `org.freedesktop.resolve1` | D-Bus-мост, который переводит вызовы в `openresolv`/`/etc/resolv.conf` |
| Сброс DNS-кэша | `RouterLinux::flushDns()` — `systemctl restart nscd/systemd-resolved` | тихо игнорируется, мост делает `nscd -i hosts` |

Из-за второго пункта после подключения ломается **весь** DNS: демон включает
iptables-цепочку `amnvpn.a.310.blockDNS`, которая режет 53-й порт, но перенастроить
резолвер не может. Отсюда «VPN подключился, а интернета нет».

## Что делает установщик

1. Находит `AmneziaVPN-service` в `/opt/AmneziaVPN` (или в `--app-dir`).
2. Определяет init-систему и ставит нативный сервис:
   - OpenRC — `/etc/init.d/amneziavpn` (`supervise-daemon`, автоперезапуск)
   - runit — `/etc/sv/amneziavpn` + лог через `svlogd`
   - s6 — `/etc/s6/sv/amneziavpn`
   - dinit — `/etc/dinit.d/amneziavpn`
   - SysVinit — `/etc/init.d/amneziavpn`
   - Slackware — `/etc/rc.d/rc.amneziavpn` + `rc.local`
   - systemd — обычный unit (для полноты)
3. Если `systemd-resolved` нет — ставит DNS-мост `amnezia-dns-bridge`:
   - поднимает на системной шине D-Bus имя `org.freedesktop.resolve1`;
   - `SetLinkDNS`/`SetLinkDomains`/`RevertLink` переводит в `resolvconf` (openresolv),
     а если его нет — аккуратно правит `/etc/resolv.conf` с бэкапом и восстановлением;
   - следит за исчезновением интерфейса и откатывает DNS.
4. Убирает старый `/etc/systemd/system/AmneziaVPN.service`, чтобы он не мешал.
5. Ставит обёртку `/usr/local/bin/AmneziaVPN` (обход отсутствующего Wayland-плагина)
   и `.desktop`-файл.

## Быстрый старт

### 1. Распаковать официальный `.run` без его установщика

Официальный инсталлятор — это Qt Installer Framework, и его `post_install.sh`
жёстко вызывает `systemctl` и копирует юнит в `/etc/systemd/system/`. Поэтому
мы не запускаем его, а распаковываем:

```bash
git clone <этот-репозиторий> amneziavpn-universal
cd amneziavpn-universal
chmod +x install.sh uninstall.sh fetch-app.sh

sudo ./fetch-app.sh --run ~/Downloads/AmneziaVPN_5.0.3.0_linux_x64.run
# или: sudo ./fetch-app.sh --version 5.0.3.0
```

Нужен `7z` (p7zip) или `binwalk`:

```bash
# Gentoo
sudo emerge --ask app-arch/p7zip
# Void
sudo xbps-install -S p7zip
# Arch
sudo pacman -S p7zip
```

Если `/opt/AmneziaVPN` уже есть после неудачной установки — этот шаг можно
пропустить.

### 2. Установить сервисы

```bash
sudo ./install.sh
```

Полезные флаги:

```bash
sudo ./install.sh --no-dns-bridge   # не ставить мост (настрою DNS сам)
sudo ./install.sh --force-x11       # GUI всегда через XWayland
sudo ./install.sh --no-start        # только установить, не запускать
```

### 3. Проверить

```bash
# OpenRC
sudo rc-service amneziavpn status
sudo rc-service amnezia-dns-bridge status

# runit
sudo sv status amneziavpn
sudo sv status amnezia-dns-bridge

# логи
tail -f /var/log/AmneziaVPN/AmneziaVPN-service.log
tail -f /var/log/AmneziaVPN/runit-amnezia-dns-bridge/current
```

Запуск GUI: `AmneziaVPN` или `/usr/local/bin/AmneziaVPN`.

## Удаление

```bash
sudo ./uninstall.sh          # снять сервисы, оставить /opt/AmneziaVPN
sudo ./uninstall.sh --purge  # удалить всё
```

## Про Wayland

`qt.qpa.plugin: Could not find the Qt platform plugin "wayland"` — это не
systemd-проблема. Официальный `.run` тащит собственный Qt 6.10.1 **без**
wayland-плагина, поэтому системный `qt6-wayland` обычно не помогает (другая
версия Qt, другой ABI). Обёртка из этого репозитория при `XDG_SESSION_TYPE=wayland`
и отсутствии плагина сама выставляет `QT_QPA_PLATFORM=xcb` (XWayland).

Подробнее: [docs/wayland.md](docs/wayland.md).

## Про DNS

Подробно, включая ручную настройку и проверку на утечки:
[docs/dns.md](docs/dns.md).

Коротко:

```bash
# что сейчас в resolv.conf
cat /etc/resolv.conf

# работает ли мост
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  string:org.freedesktop.resolve1
```

## Структура

```
install.sh / uninstall.sh / fetch-app.sh
lib/common.sh                 детект init, поиск бинарников, шаблоны
init/<init>/service.template  нативные сервисы
dns/amnezia-dns-bridge.py     D-Bus-шим org.freedesktop.resolve1
dns/org.freedesktop.resolve1.conf  политика D-Bus (только root)
docs/                         wayland, dns, s6, slackware
patches/                      нативный патч (в разработке)
```

## Тестирование

Проверять нужно на чистой системе, а не на Arch с systemd. Минимальный набор:

```bash
# Void Linux (runit) в QEMU
qemu-system-x86_64 -m 4G -enable-kvm -cdrom void-live-x86_64-*.iso

# Gentoo (OpenRC) — stage3 + chroot или тоже VM
```

Чек-лист:

- [ ] сервис стартует и переживает `kill -9` (supervise-daemon/runit)
- [ ] клиент видит демон (нет `Ipc::Init failed`)
- [ ] после подключения `cat /etc/resolv.conf` содержит DNS из конфига VPN
- [ ] `dig +short example.com` работает
- [ ] после отключения `/etc/resolv.conf` восстановлен
- [ ] после `rc-service amneziavpn stop` нет цепочек `amnvpn.*` в `iptables -S`
- [ ] перезагрузка → всё поднимается само

## Дорожная карта

1. **Сейчас:** установщик + init-скрипты + DNS-мост (работает с официальным бинарником).
2. **Дальше:** нативный патч `DnsUtilsLinux` (resolved → openresolv → файл) и
   обработка `SIGTERM` в демоне, чтобы не оставалось правил. Это можно отправить
   в upstream (issues [#775](https://github.com/amnezia-vpn/amnezia-client/issues/775),
   [#3000](https://github.com/amnezia-vpn/amnezia-client/issues/3000)).
3. **Потом:** ebuild для Gentoo, xbps-template для Void, SlackBuild, CI-сборка.

## Лицензия

GPL-3.0-or-later, как и сам AmneziaVPN.
