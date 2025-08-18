# QUICK START — Быстрая установка и проверка WireGuard сервера

Этот файл — упрощённый шаг за шагом план для быстрой настройки сервера и базовой проверки. Предполагается, что вы используете Debian 12 и выполняете команды под root.

ВАЖНО: директория `clients/` не изменяется этими инструкциями (конфиги клиентов хранятся там).

1) Скачайте репозиторий / установочные скрипты (на сервере)
```bash
# из каталога, куда хотите скачать
git clone https://github.com/spochipov/wireguard_quickstart.git
cd wireguard_quickstart
# или только wg-server-setup.sh
wget https://raw.githubusercontent.com/spochipov/wireguard_quickstart/main/wg-server-setup.sh
chmod +x wg-server-setup.sh
```

2) Запустите установочный скрипт
```bash
./wg-server-setup.sh
```
Что делает скрипт:
- Обновляет пакеты и устанавливает зависимости (wireguard, iptables и пр.).
- Генерирует ключи и создаёт `/etc/wireguard/wg0.conf`.
- Настраивает оптимизации sysctl для производительности.
- Устанавливает утилиты в каталог `/usr/local/bin/wg-tools/` и создаёт символьные ссылки в `/usr/local/bin/` для обратной совместимости (например: `/usr/local/bin/wg-add-client`, `/usr/local/bin/wg-server-info`, `/usr/local/bin/wg-backup`).
- Настраивает базовый firewall и NAT (iptables/ip6tables/nat).
- Запускает и включит сервис `wg-quick@wg0`.

3) Быстрая проверка после установки
```bash
# Проверить статус WireGuard
systemctl status wg-quick@wg0

# Проверить интерфейс и адреса
ip addr show wg0

# Проверить NAT и правила
iptables -t nat -L POSTROUTING -n -v
iptables -L INPUT -n --line-numbers
iptables -L FORWARD -n --line-numbers
```

4) Добавление клиента
```bash
# Если утилиты установлены в /usr/local/bin (или в /usr/local/bin/wg-tools/):
/usr/local/bin/wg-add-client <client_name>

# Альтернативно (если запускаете из репозитория):
server-tools/wg-add-client.sh <client_name>
```
- Файл клиента сохранится в `/etc/wireguard/clients/<client_name>.conf`.
- Скрипт автоматически добавит Peer в `/etc/wireguard/wg0.conf` и выполнит `wg syncconf`/reload.

5) См. клиентскую конфигурацию и QR
```bash
cat /etc/wireguard/clients/<client_name>.conf
# Отобразить QR (если установлен qrencode)
qrencode -t ansiutf8 < /etc/wireguard/clients/<client_name>.conf
```

6) Смена порта WireGuard (если нужно)
Утилита: `wg-change-port` (устанавливается в `/usr/local/bin/wg-tools/` и для удобства доступна как симлинк `/usr/local/bin/wg-change-port`).
```bash
# Пример: сменить на 51821
/usr/local/bin/wg-change-port 51821

# Что делает:
# - Резервная копия wg0.conf
# - Обновляет ListenPort в /etc/wireguard/wg0.conf
# - Удаляет старые INPUT-правила, добавляет новые для нового порта (iptables/ip6tables)
# - Пытается обновить UFW / firewalld (если они установлены)
# - Перезапускает wg-quick@wg0
# - Сохраняет правила через netfilter-persistent (если установлен)
```

7) Сохранение правил firewall между перезагрузками
Рекомендуется установить:
```bash
apt update
apt install -y iptables-persistent netfilter-persistent
# во время установки согласитесь сохранить текущие правила
netfilter-persistent save
```
Если пакет не устанавливается, скрипты сохраняют правила в `/etc/iptables/rules.v4` и `/etc/iptables/rules.v6` (если каталог существует).

8) Диагностика проблем с доступом в интернет (сервер)
- Запустите диагностический скрипт:
```bash
/usr/local/bin/wg-debug-internet    # если установлен в /usr/local/bin
# или (из репозитория)
./wg-debug-internet.sh
```
- Для расширенного сбора логов/правил:
```bash
# (Если нужен расширенный сбор) Используйте diagnostics вручную или запустите `wg-debug-internet` и сохраните выводы:
# Пример:
wg-debug-internet > /tmp/wg-debug-$(date +%s).log 2>&1
iptables-save > /tmp/iptables-$(date +%s).rules
ip6tables-save > /tmp/ip6tables-$(date +%s).rules
# Сохранённые файлы можно собрать в один архив вручную:
tar -czf /tmp/wg-diagnostics-$(date +%s).tar.gz /tmp/wg-debug-*.log /tmp/iptables-*.rules /tmp/ip6tables-*.rules
# Это заменяет устаревший scripts/run-wg-diagnostics-and-collect.sh
```

9) Быстрые тесты с клиента
- Подключитесь клиентом и проверьте:
  - ping 8.8.8.8
  - curl https://ifconfig.co (покажет внешний IP после SNAT)
  - dig @1.1.1.1 example.com (проверка DNS)
- Если клиент не выходит в интернет, убедитесь что:
  - NAT (MASQUERADE) настроен для подсети клиентов
  - FORWARD политика и правила разрешают трафик
  - /etc/wireguard/wg0.conf PostUp содержит необходимые iptables команды (обычно настроено скриптом установки)

10) Дополнительно / полезные команды
```bash
# Показать активные соединения WireGuard
wg show wg0

# Показать список клиентов (если установлено)
wg-list-clients

# Резервное копирование конфигураций
wg-backup
```

11) Примечания по безопасности
- Держите приватные ключи в /etc/wireguard/keys с правами 600.
- Регулярно обновляйте систему и WireGuard:
```bash
apt update && apt upgrade
```

12) Где читать дальше
- README.md — обзор проекта и структура
- scripts/README.md — описание вспомогательных скриптов
- QUICK_START.md — (этот файл) — для быстрого старта
