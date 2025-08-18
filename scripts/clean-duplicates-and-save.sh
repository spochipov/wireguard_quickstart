#!/bin/bash
# Удалить дублирующиеся INPUT-правила для UDP 51820 (WireGuard) и сохранить правила.
# Запускать от root:
#   chmod +x scripts/clean-duplicates-and-save.sh
#   ./scripts/clean-duplicates-and-save.sh
#
set -euo pipefail

WG_PORT=51820

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Команда $1 не найдена, прерываю."; exit 1; }
}

require_cmd iptables-save
require_cmd iptables
require_cmd ip6tables-save || true
require_cmd ip6tables || true

echo "1) Показать текущие правила INPUT (iptables):"
iptables -L INPUT -n --line-numbers || true
echo

# IPv4: найти все правила с --dport WG_PORT в выводе iptables-save
echo "2) Поиск правил с --dport $WG_PORT в iptables-save (IPv4)..."
IPV4_RULES=$(iptables-save | grep -- "--dport $WG_PORT" || true)
echo "$IPV4_RULES" | sed -n '1,50p'
echo

if [ -z "$IPV4_RULES" ]; then
  echo "Правил для udp dport $WG_PORT в iptables не найдено."
else
  # Оставляем первую строку, удаляем остальные
  FIRST_IPV4_RULE=$(echo "$IPV4_RULES" | sed -n '1p')
  REMAIN_IPV4=$(echo "$IPV4_RULES" | sed -n '2,$p' || true)

  if [ -n "$REMAIN_IPV4" ]; then
    echo "Найдены дубликаты IPv4 правил. Удаляю все кроме первой..."
    echo "Оставляем:"
    echo "$FIRST_IPV4_RULE"
    echo

    echo "$REMAIN_IPV4" | while IFS= read -r line; do
      # line имеет формат: -A INPUT ...
      # Преобразуем в команду удаления: iptables -D INPUT ...
      del_cmd=$(printf "%s" "$line" | sed -E 's/^-A ([^ ]+) /iptables -D \1 /')
      echo "+ $del_cmd"
      # Выполнить удаление
      eval "$del_cmd" || echo "Не удалось удалить правило: $del_cmd"
    done
  else
    echo "Дубликатов IPv4 правил не найдено (есть только одно правило)."
  fi
fi

echo
echo "3) IPv6: поиск правил в ip6tables-save (если доступно)..."
if command -v ip6tables-save >/dev/null 2>&1; then
  IPV6_RULES=$(ip6tables-save | grep -- "--dport $WG_PORT" || true)
  echo "$IPV6_RULES" | sed -n '1,50p'
  echo

  if [ -n "$IPV6_RULES" ]; then
    FIRST_IPV6_RULE=$(echo "$IPV6_RULES" | sed -n '1p')
    REMAIN_IPV6=$(echo "$IPV6_RULES" | sed -n '2,$p' || true)

    if [ -n "$REMAIN_IPV6" ]; then
      echo "Найдены дубликаты IPv6 правил. Удаляю все кроме первой..."
      echo "Оставляем:"
      echo "$FIRST_IPV6_RULE"
      echo

      echo "$REMAIN_IPV6" | while IFS= read -r line; do
        del_cmd=$(printf "%s" "$line" | sed -E 's/^-A ([^ ]+) /ip6tables -D \1 /')
        echo "+ $del_cmd"
        eval "$del_cmd" || echo "Не удалось удалить правило: $del_cmd"
      done
    else
      echo "Дубликатов IPv6 правил не найдено (есть только одно правило)."
    fi
  else
    echo "Правил udp dport $WG_PORT в ip6tables не найдено."
  fi
else
  echo "ip6tables-save не доступен, пропускаю IPv6 шаг."
fi

echo
echo "4) Проверка результата (iptables INPUT):"
iptables -L INPUT -n --line-numbers || true
echo
echo "5) Сохранение правил в /etc/iptables (создаю каталог и записываю файлы)"
# Создать каталог, если нужно
if [ ! -d /etc/iptables ]; then
  mkdir -p /etc/iptables
fi

echo "Сохраняю IPv4 правила в /etc/iptables/rules.v4"
iptables-save > /etc/iptables/rules.v4

if command -v ip6tables-save >/dev/null 2>&1; then
  echo "Сохраняю IPv6 правила в /etc/iptables/rules.v6"
  ip6tables-save > /etc/iptables/rules.v6 || echo "Ошибка при сохранении ip6tables (может быть отсутствует файл/каталог)"
else
  echo "ip6tables-save недоступен — IPv6 правила не сохранены."
fi

echo
echo "6) Рекомендация: установить iptables-persistent/netfilter-persistent для автоматической загрузки правил при загрузке."
echo "  apt update && apt install -y iptables-persistent netfilter-persistent"
echo "  netfilter-persistent save"
echo
echo "Готово."
