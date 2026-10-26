# DNS без systemd-resolved

## Как это устроено в AmneziaVPN

Демон (`AmneziaVPN-service`) на Linux настраивает DNS только через D-Bus-сервис
`org.freedesktop.resolve1` (systemd-resolved). В `DnsUtilsLinux` вызываются:

- `SetLinkDNS(ifindex, [(family, address)])`
- `SetLinkDomains(ifindex, [(domain, search)])`
- `SetLinkDefaultRoute(ifindex, bool)`
- `RevertLink(ifindex)`
- `Properties.Get("Domains")`

Одновременно `LinuxFirewall` включает цепочку `amnvpn.a.310.blockDNS`:

```
-p udp --dport 53 -j REJECT
-p tcp --dport 53 -j REJECT
```

и разрешает DNS только в сторону серверов из конфига VPN через туннель.

Если `resolve1` нет, получается худший вариант: **старый резолвер заблокирован,
новый не настроен**. Отсюда «интернета нет».

## Как работает мост

`amnezia-dns-bridge` — маленький демон на системной шине D-Bus. Он:

1. Занимает имя `org.freedesktop.resolve1` (и отказывается стартовать, если имя
   уже занято настоящим systemd-resolved — поэтому его безопасно держать
   установленным и на systemd-системах).
2. Запоминает DNS/домены по `ifindex`.
3. Применяет их через:
   - `resolvconf -a amneziavpn -x -m 0` (openresolv; на Gentoo и Void он есть);
   - либо напрямую в `/etc/resolv.conf` с бэкапом в `/var/lib/amneziavpn/`.
4. По `RevertLink` или исчезновению интерфейса откатывает изменения.
5. По `SIGTERM` восстанавливает исходный `/etc/resolv.conf`.

## Ручная настройка (если мост не нужен)

### openresolv

```bash
# Gentoo
sudo emerge --ask net-misc/openresolv
# Void
sudo xbps-install -S openresolv
```

Проверь, что `/etc/resolv.conf` — симлинк на управляемый файл:

```bash
ls -l /etc/resolv.conf
```

### Без openresolv

Можно жить с обычным `/etc/resolv.conf`, но придётся вручную прописывать DNS
из конфига VPN после каждого подключения. Это неудобно и приводит к утечкам,
поэтому лучше поставить мост.

## Временный обход: не блокировать DNS

Если нужно срочно проверить связь, можно отключить блокировку (DNS будет
уходить мимо туннеля — это утечка, только для диагностики):

```bash
sudo iptables -F amnvpn.a.310.blockDNS
```

После отключения VPN обязательно проверь, что цепочки не остались:

```bash
sudo iptables -S | grep amnvpn
```

## Проверка

```bash
# мост жив?
sudo sv status amnezia-dns-bridge          # runit
sudo rc-service amnezia-dns-bridge status  # OpenRC

# имя на шине занято?
dbus-send --system --print-reply --dest=org.freedesktop.DBus \
  /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
  string:org.freedesktop.resolve1

# что реально в resolv.conf
cat /etc/resolv.conf

# резолвинг
dig +short example.com
```

## Утечки DNS

Проверить, что запросы идут через VPN:

```bash
# на сервере VPN смотри tcpdump по 53-му порту
sudo tcpdump -ni any port 53

# на клиенте
dig +short whoami.akamai.net
```

Если в `resolv.conf` остался домашний роутер, а firewall его не блокирует —
это утечка. Мост как раз нужен, чтобы этого не было.
