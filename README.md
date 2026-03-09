# VPS Hardening Script

Интерактивный Bash-скрипт для быстрого и безопасного hardening VPS на Ubuntu/Debian.

Скрипт делает то, что обычно настраивают руками после первого входа:
- обновляет систему,
- создает нового admin-пользователя,
- настраивает SSH,
- применяет UFW по выбранной модели доступа,
- настраивает Fail2ban,
- включает автообслуживание,
- выводит детальный финальный отчет.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh | sudo bash
```

## Быстрый rollback

```bash
curl -fsSL https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh | sudo bash -s -- --rollback
```

## Быстрое удаление hardening

```bash
curl -fsSL https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh | sudo bash -s -- --uninstall
```

## Что происходит по шагам

1. Предпроверки и старт.
2. Выбор модели доступа:
- `all` - открыть только SSH порт (из шага 4) для всех.
- `selected` - построить ACL-таблицу правил (`source + port`).
3. Обновление системы (`apt update`, `apt upgrade -y`).
4. Создание нового пользователя, генерация пароля, удаление лишних пользователей.
5. Генерация SSH-ключей (`ed25519`) + passphrase.
6. SSH hardening и выбор нового SSH порта.
7. UFW hardening.
8. Fail2ban hardening.
9. Проверки/перезапуски и финальный отчет.

## ACL и UFW (важное)

В режиме `selected` скрипт работает через apply-список:
- внутри формируется нормализованный список пар `source+port`,
- UFW применяет только этот список,
- если правило в ACL с `__SSH__` или именем `*:ssh`, то на шаге 4 порт автоматически обновляется на новый SSH-порт,
- после применения идет проверка, что все пары попали в UFW; недостающие добавляются повторно.

Пример:

ACL:
- `46.233.196.229 + __SSH__`
- `any + 80`
- `any + 443`

После шага 4 (например SSH порт = `2222`) UFW применит:

```bash
ufw allow from 46.233.196.229 to any port 2222 proto tcp
ufw allow 80/tcp
ufw allow 443/tcp
```

### Диапазоны портов

- Для SSH-порта (шаг 4): `1024-65535`.
- Для ACL-портов (правила): `0-65535`.

## Fail2ban политика

`jail.local` создается с фиксированным баном:
- `ignoreip = 127.0.0.1/8 ::1 <ваш SSH connected IP>`
- `bantime = 86400`
- `findtime = 300`
- `maxretry = 3`
- `sshd.port = выбранный SSH порт`

Без инкрементального роста банов: только 24 часа.

Если `fail2ban-client status sshd` вернет ошибку (например `255`), скрипт не падает: выполняется fallback-проверка общего статуса Fail2ban.

## Rollback

Скрипт сохраняет snapshot перед изменениями в:

```text
/var/backups/vps_hardening/<timestamp>/
```

Запуск rollback:

```bash
sudo bash vps_hardening.sh --rollback
```

Что делает rollback:
- восстанавливает ключевые файлы из snapshot,
- перезагружает UFW (`ufw reload`), затем отключает UFW (`ufw disable`),
- включает вход по паролю в `sshd_config`,
- комментирует key-based строки (`PubkeyAuthentication`, `AuthorizedKeysFile`),
- проверяет `sshd -t` и перезапускает `sshd` (с fallback на `ssh`).

## Uninstall

`--uninstall`:
- сначала пытается восстановить систему через rollback (если есть snapshot/state),
- затем удаляет артефакты hardening,
- удаляет `fail2ban`/`ufw` только если они были установлены скриптом,
- удаляет логи/конфиги/таймеры/временные данные hardening.

Важно: `apt update/upgrade` как факт обновления пакетов назад не откатывается.

## Что вы получите в финальном отчете

- `IP:port`
- команда подключения
- `user/password`
- `private key/public key/passphrase`
- ACL таблица
- UFW статус + список разрешенных правил
- Fail2ban статус
- статус auto-maintenance
- готовые команды rollback и uninstall

## Надежность и UX

Скрипт учитывает реальные edge-cases:
- строгое подтверждение `Y/n` (некорректный ввод не принимается),
- корректная работа с pipe-запуском через TTY,
- обработка ошибок с выбором `continue/exit`,
- fallback-механизмы при нестандартном окружении.

Интерфейс унифицирован:
- повторяемые шаги,
- единый стиль блоков,
- стабильные таблицы с усечением длинных значений (рамки не ломаются).

## После запуска: быстрый чек

```bash
# SSH
systemctl status sshd || systemctl status ssh

# UFW
ufw status verbose

# Fail2ban
fail2ban-client status
fail2ban-client status sshd

# Таймер обслуживания
systemctl status vps-hardening-maintenance.timer
systemctl list-timers | grep vps-hardening
```

## Частые ситуации

1. Не пускает по SSH после hardening.
- Проверьте порт, ACL-правила и UFW.
- Используйте консоль провайдера, если потерян доступ.

2. `Permission denied (publickey)`.
- Проверьте, что используете private key и passphrase из финального отчета.

3. Fail2ban заблокировал ваш IP.
- Разбан:

```bash
fail2ban-client set sshd unbanip <IP>
```

## Аргументы CLI

- `--dry-run` - симуляция без изменений.
- `--rollback` - откат последнего запуска.
- `--uninstall` - удаление hardening-артефактов.
- `--help` - справка.

## Совместимость

- Ubuntu `20.04+`
- Debian `11+`
