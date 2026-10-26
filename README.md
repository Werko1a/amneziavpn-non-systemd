# amneziavpn-universal

Запуск официального клиента **AmneziaVPN** на Linux **без systemd** — Gentoo/OpenRC,
Void/runit, Artix, Alpine, Devuan, Slackware и любых других init-системах.

> Статус: **протестировано (working)**. Базовый стек, сервисы и DNS-мост успешно
> проверены на живой системе Artix Linux (OpenRC). См. раздел «Тестирование».

---

## Зачем это нужно

В самом демоне AmneziaVPN (`AmneziaVPN-service`) **нет вызовов systemd**. Это
обычный Qt-процесс, который слушает unix-сокеты. systemd нужен только в трёх
местах:

| Что | Где | Как решаем |
|---|---|---|
| Запуск и перезапуск демона | `deploy/data/linux/AmneziaVPN.service`, `systemctl` в `post_install.sh` | нативные сервисы с автоперезапуском под любой init |
| Настройка DNS | `client/platforms/linux/daemon/dnsutilslinux.cpp` — D-Bus `org.freedesktop.resolve1` | D-Bus-мост, который переводит вызовы в `openresolv`/`/etc/resolv.conf` |
| Сброс DNS-кэша | `RouterLinux::flushDns()` — `systemctl restart nscd/systemd-resolved` | тихо игнорируется, мост делает `nscd -i hosts` |

Из-за второго пункта после подключения ломается **весь** DNS: демон включает
iptables-цепочку `amnvpn.a.310.blockDNS`, которая режет 53-й порт, но перенастроить
резолвер не может. Отсюда «VPN подключился, а интернета нет».

## Что делает установщик

1. Находит `AmneziaVPN-service` в `/opt/AmneziaVPN` (или в `--app-dir`).
2. Определяет init-систему и ставит нативный сервис с **автоперезапуском (переживает `kill -9`)**:
   - **OpenRC** — `/etc/init.d/amneziavpn` (`supervise-daemon`)
   - **runit** — `/etc/sv/amneziavpn` (`runsv` + лог через `svlogd`)
   - **s6** — `/etc/s6/sv/amneziavpn` (`s6-supervise`)
   - **dinit** — `/etc/dinit.d/amneziavpn` (нативный `restart = true`)
   - **SysVinit / Slackware** — `/etc/init.d/amneziavpn` (встроенный watchdog-надзиратель)
   - **systemd** — юнит с `Restart=always` (для систем без `systemd-resolved`)
3. Автоматически зачищает `iptables` / `ip6tables` (прыжки и цепочки во всех таблицах `filter`, `nat`, `mangle`) при остановке службы.
4. Если `systemd-resolved` отсутствует — ставит DNS-мост `amnezia-dns-bridge`:
   - поднимает на системной шине D-Bus имя `org.freedesktop.resolve1`;
   - переводит вызовы в `openresolv`, а если его нет — аккуратно правит `/etc/resolv.conf` с бэкапом и восстановлением;
   - следит за исчезновением интерфейса и откатывает DNS обратно.
5. Убирает официальный `/etc/systemd/system/AmneziaVPN.service`, чтобы он не конфликтовал.
6. Ставит обёртку `/usr/local/bin/AmneziaVPN` (обход бага с Wayland) и `.desktop`-ярлык.

## Быстрый старт

### 1. Распаковать официальный `.run` без его установщика

Официальный инсталлятор жестко завязан на `systemctl`. Поэтому мы не запускаем его, а распаковываем:

```bash
git clone https://github.com/Werko1a/amneziavpn-non-systemd.git amneziavpn-universal
cd amneziavpn-universal
chmod +x install.sh uninstall.sh fetch-app.sh

sudo ./fetch-app.sh --run ~/Downloads/AmneziaVPN_5.0.3.0_linux_x64.run
# или скачать автоматически:
# sudo ./fetch-app.sh --version 5.0.3.0
```

Для распаковщика нужен `p7zip` (или `7z`):

```bash
# Artix / Arch
sudo pacman -S p7zip
# Void
sudo xbps-install -S p7zip
# Gentoo
sudo emerge --ask app-arch/p7zip
```

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
sudo ./uninstall.sh --purge  # удалить всё полностью
```

## Про Wayland

Официальный `.run` собирается со своим встроенным Qt 6.10 **без** wayland-плагина (`libqwayland`). Обёртка `/usr/local/bin/AmneziaVPN` при обнаружении Wayland-сессии сама переключает запуск на XWayland (`QT_QPA_PLATFORM=xcb`).

Подробнее: [docs/wayland.md](docs/wayland.md).

## Про DNS

Подробно о проверке на утечки и ручной настройке: [docs/dns.md](docs/dns.md).

Короткая проверка работы моста:

```bash
# что сейчас в resolv.conf
cat /etc/resolv.conf

# активен ли мост на шине D-Bus
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  string:org.freedesktop.resolve1
```

## Структура

```
install.sh / uninstall.sh / fetch-app.sh
lib/common.sh                 детект init, поиск бинарников, шаблоны
init/<init>/service.template  шаблоны нативных сервисов
dns/amnezia-dns-bridge.py     D-Bus-шим org.freedesktop.resolve1
dns/org.freedesktop.resolve1.conf  политика D-Bus (только root)
docs/                         wayland, dns, s6, slackware
patches/                      нативный патч (в разработке)
```

## Тестирование

Протестировано на живой системе **Artix Linux (OpenRC)**:

- [x] сервис стартует и переживает `kill -9` (`supervise-daemon` мгновенно воскрешает процесс)
- [x] клиент видит демон (нет `Ipc::Init failed`)
- [x] после подключения `cat /etc/resolv.conf` содержит DNS из конфига VPN
- [x] `dig +short example.com` работает корректно через туннель
- [x] после отключения `/etc/resolv.conf` полностью восстанавливается в исходное состояние
- [x] после остановки сервиса нет зависших цепочек `amnvpn.*` в `iptables -S` (полная зачистка всех таблиц)
- [x] автозапуск после загрузки настроен во всех поддерживаемых init-системах

## Дорожная карта

1. **Сейчас:** универсальный установщик + супервизор-скрипты + DNS-мост (работает из коробки с официальным бинарником).
2. **Дальше:** нативный патч `DnsUtilsLinux` в исходники Amnezia (замена resolved на прямой resolvconf) для отправки в upstream если его конечно примут xd.
3. **Потом:** пакеты в репозитории: ebuild (Gentoo), xbps-src (Void), AUR/Artix, SlackBuild.

## Лицензия

GPL-3.0-or-later, как и сам AmneziaVPN.
