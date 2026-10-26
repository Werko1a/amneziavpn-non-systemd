# Slackware

Slackware 15 использует SysVinit-подобные скрипты в `/etc/rc.d/` и `rc.local`.
Установщик определит Slackware по `/etc/slackware-version` и положит сервис в
`/etc/rc.d/rc.amneziavpn`, добавив запуск в `/etc/rc.d/rc.local`.

## Зависимости

Из коробки в Slackware 15 есть `python3`, но нет `dbus-python` и `PyGObject`.
Варианты:

### Вариант A: поставить из SBo

```bash
sudo sbopkg -i dbus-python
sudo sbopkg -i pygobject3
```

### Вариант B: pip в venv (не рекомендуется для системного демона)

Лучше не смешивать pip с системным Python. Если очень нужно:

```bash
sudo python3 -m pip install --break-system-packages dbus-python pygobject
```

### Вариант C: без моста

```bash
sudo ./install.sh --no-dns-bridge
```

Тогда DNS настраивается вручную (см. [dns.md](dns.md)).

## Установка

```bash
sudo ./fetch-app.sh --run ~/Downloads/AmneziaVPN_*_linux_x64.run
sudo ./install.sh
```

## Управление

```bash
sudo /etc/rc.d/rc.amneziavpn start
sudo /etc/rc.d/rc.amneziavpn stop
sudo /etc/rc.d/rc.amneziavpn restart
sudo /etc/rc.d/rc.amneziavpn status
```

## Автозапуск

Установщик добавляет в `/etc/rc.d/rc.local`:

```sh
[ -x /etc/rc.d/rc.amneziavpn ] && /etc/rc.d/rc.amneziavpn start
```

Проверь, что `rc.local` исполняемый:

```bash
sudo chmod +x /etc/rc.d/rc.local
```
