# Docker Testing Environment для WireGuard

Этот Docker Compose файл создает изолированную среду для тестирования WireGuard сервера на чистом Debian 12.

## 🐳 Быстрый старт

### 1. Запуск контейнера сервера

```bash
# Запустить только сервер
docker-compose up -d wireguard-server

# Подключиться к контейнеру
docker exec -it wireguard-test-server bash
```

### 2. Установка WireGuard в контейнере

```bash
# Внутри контейнера выполнить:
chmod +x /root/wg-server-setup.sh
/root/wg-server-setup.sh
```

### 3. Добавление клиентов

```bash
# Внутри контейнера:
wg-add-client test-client
wg-list-clients
```

## 📁 Структура данных

После запуска создается следующая структура:

```
docker-data/
├── wireguard/          # Конфигурации WireGuard
│   ├── wg0.conf        # Основной конфиг сервера
│   ├── keys/           # Ключи сервера
│   └── clients/        # Конфигурации клиентов
├── sysctl/             # Системные параметры
├── ufw/                # Настройки брандмауэра
└── scripts/            # Установленные скрипты управления
```

## 🔧 Команды Docker Compose

### Основные команды

```bash
# Запустить сервер
docker-compose up -d wireguard-server

# Запустить сервер + тестовый клиент
docker-compose --profile testing up -d

# Подключиться к серверу
docker exec -it wireguard-test-server bash

# Подключиться к клиенту
docker exec -it wireguard-test-client bash

# Просмотр логов
docker-compose logs -f wireguard-server

# Остановить все
docker-compose down

# Остановить и удалить данные
docker-compose down -v
```

### Управление данными

```bash
# Создать бэкап конфигураций
docker exec wireguard-test-server wg-backup

# Скопировать конфиг клиента на хост
docker cp wireguard-test-server:/etc/wireguard/clients/test-client.conf ./

# Просмотр статуса WireGuard
docker exec wireguard-test-server wg show
```

## 🧪 Тестирование

### Тест 1: Установка сервера

```bash
# 1. Запустить контейнер
docker-compose up -d wireguard-server

# 2. Установить WireGuard
docker exec -it wireguard-test-server bash -c "
    chmod +x /root/wg-server-setup.sh && 
    /root/wg-server-setup.sh
"

# 3. Проверить статус
docker exec wireguard-test-server systemctl status wg-quick@wg0
```

### Тест 2: Добавление клиентов

```bash
# Добавить несколько клиентов
docker exec wireguard-test-server wg-add-client laptop
docker exec wireguard-test-server wg-add-client phone
docker exec wireguard-test-server wg-add-client tablet

# Проверить список
docker exec wireguard-test-server wg-list-clients
```

### Тест 3: Тестирование клиента

```bash
# Запустить тестовый клиент
docker-compose --profile testing up -d wireguard-client

# Скопировать конфиг в клиент
docker cp docker-data/wireguard/clients/laptop.conf wireguard-test-client:/etc/wireguard/

# Подключиться в клиенте
docker exec wireguard-test-client wg-quick up laptop

# Проверить подключение
docker exec wireguard-test-client ping 10.x.x.1  # IP сервера из конфига
```

## 🔍 Отладка

### Просмотр логов

```bash
# Логи контейнера
docker-compose logs wireguard-server

# Логи WireGuard
docker exec wireguard-test-server journalctl -u wg-quick@wg0 -f

# Системные логи
docker exec wireguard-test-server dmesg | grep wireguard
```

### Проверка сети

```bash
# Проверить интерфейсы
docker exec wireguard-test-server ip addr show

# Проверить маршруты
docker exec wireguard-test-server ip route show

# Проверить правила iptables
docker exec wireguard-test-server iptables -L -n -v
docker exec wireguard-test-server ip6tables -L -n -v
```

### Проверка конфигурации

```bash
# Проверить конфиг WireGuard
docker exec wireguard-test-server cat /etc/wireguard/wg0.conf

# Проверить статус сервиса
docker exec wireguard-test-server systemctl status wg-quick@wg0

# Проверить активные подключения
docker exec wireguard-test-server wg show
```

## ⚠️ Ограничения Docker среды

### Сетевые ограничения

- Используется `network_mode: host` для доступа к сетевым интерфейсам
- Требуются привилегированные права (`privileged: true`)
- Некоторые сетевые функции могут работать по-разному

### Системные ограничения

- UFW может работать не полностью в контейнере
- Некоторые системные сервисы могут быть недоступны
- Модули ядра загружаются на хосте

### Рекомендации

1. **Для разработки**: Используйте Docker среду
2. **Для продакшена**: Используйте реальный VPS с Debian 12
3. **Для тестирования**: Docker отлично подходит для проверки скриптов

## 🔄 Сброс среды

```bash
# Полный сброс
docker-compose down -v
sudo rm -rf docker-data/
docker-compose up -d wireguard-server

# Сброс только WireGuard
docker exec wireguard-test-server systemctl stop wg-quick@wg0
docker exec wireguard-test-server rm -rf /etc/wireguard/*
```

## 📝 Примеры использования

### Автоматическая установка

```bash
# Одной командой: запуск + установка
docker-compose up -d wireguard-server && \
sleep 10 && \
docker exec wireguard-test-server bash -c "
    chmod +x /root/wg-server-setup.sh && 
    /root/wg-server-setup.sh && 
    wg-add-client test-device
"
```

### Экспорт конфигураций

```bash
# Экспорт всех клиентских конфигов
mkdir -p ./exported-configs
docker exec wireguard-test-server find /etc/wireguard/clients -name "*.conf" -exec basename {} \; | \
while read config; do
    docker cp "wireguard-test-server:/etc/wireguard/clients/$config" "./exported-configs/"
done
```

### Мониторинг

```bash
# Непрерывный мониторинг подключений
watch -n 5 'docker exec wireguard-test-server wg show'

# Мониторинг трафика
docker exec wireguard-test-server iftop -i wg0
```

---

**Примечание**: Docker среда предназначена для тестирования и разработки. Для продакшена используйте реальный VPS.
