#!/bin/sh
# Скрипт с рекомендуемыми командами для настройки iptables/ip6tables для WireGuard
# Сохраните файл и запустите вручную на сервере от root:
#   chmod +x scripts/wg-firewall-recommendations.sh
#   # Для реального применения установите APPLY=1 или запустите с аргументом apply
#   ./scripts/wg-firewall-recommendations.sh        # по умолчанию только печатает команды (без применения)
#   ./scripts/wg-firewall-recommendations.sh apply  # применит команды
#
# Перед запуском убедитесь, что вы понимаете команды. Скрипт добавляет правила, не удаляя старые.
#
APPLY=0
if [ "$1" = "apply" ]; then
  APPLY=1
fi

echocmd() {
  printf "+ %s\n" "$*"
  if [ "$APPLY" -eq 1 ]; then
    eval "$@"
  fi
}

echo "WireGuard firewall recommendations script"
echo "APPLY mode: $APPLY (0 = dry-run, 1 = apply)"

# Переменные (проверьте интерфейс внешнего выхода)
WG_IF="wg0"
EXT_IF="ens192"
WG_PORT="51820"
WG_NET_V4="10.174.38.0/24"
WG_NET_V6="fd67:db4c:8d28:200::/64"

echo
echo "1) Разрешить входящий UDP на порт WireGuard (IPv4 + IPv6)"
echocmd iptables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 || echocmd iptables -A INPUT -p udp --dport "$WG_PORT" -m comment --comment "allow WireGuard" -j ACCEPT
echocmd ip6tables -C INPUT -p udp --dport "$WG_PORT" -j ACCEPT >/dev/null 2>&1 || echocmd ip6tables -A INPUT -p udp --dport "$WG_PORT" -m comment --comment "allow WireGuard v6" -j ACCEPT

echo
echo "2) Явные правила FORWARD между $WG_IF и $EXT_IF"
# IPv4: от wg к внешнему интерфейсу (исходящий от клиентов)
echocmd iptables -C FORWARD -i "$WG_IF" -o "$EXT_IF" -j ACCEPT >/dev/null 2>&1 || echocmd iptables -A FORWARD -i "$WG_IF" -o "$EXT_IF" -j ACCEPT
# IPv4: возвращённый трафик (снаружи к клиенту)
echocmd iptables -C FORWARD -i "$EXT_IF" -o "$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || echocmd iptables -A FORWARD -i "$EXT_IF" -o "$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

# IPv6 аналогично (если нужен форвард IPv6)
echocmd ip6tables -C FORWARD -i "$WG_IF" -o "$EXT_IF" -j ACCEPT >/dev/null 2>&1 || echocmd ip6tables -A FORWARD -i "$WG_IF" -o "$EXT_IF" -j ACCEPT
echocmd ip6tables -C FORWARD -i "$EXT_IF" -o "$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || echocmd ip6tables -A FORWARD -i "$EXT_IF" -o "$WG_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT

echo
echo "3) NAT (MASQUERADE) — привязать к внешнему интерфейсу"
# Проверяем, не существует ли уже аналогичного правила
if iptables -t nat -C POSTROUTING -s "$WG_NET_V4" -o "$EXT_IF" -j MASQUERADE >/dev/null 2>&1; then
  echo "NAT правило уже существует."
else
  echocmd iptables -t nat -A POSTROUTING -s "$WG_NET_V4" -o "$EXT_IF" -j MASQUERADE
fi

echo
echo "4) Проверка ip_forward (покажет 1 если включено)"
echocmd sysctl net.ipv4.ip_forward
echocmd sysctl net.ipv6.conf.all.forwarding

echo
echo "5) Сохранение правил (если хотите сохранить их между перезагрузками)"
echo "  На Debian/Ubuntu рекомендуется iptables-persistent / netfilter-persistent"
echo "  Пример команд (не выполняются автоматически в dry-run):"
echo "    apt update && apt install -y iptables-persistent"
echo "    netfilter-persistent save"
echo
echo "6) Быстрые проверки после применения:"
echo "  iptables -L INPUT -n --line-numbers"
echo "  ip6tables -L INPUT -n --line-numbers"
echo "  iptables -L FORWARD -n -v"
echo "  iptables -t nat -L POSTROUTING -n -v"
echo "  ping -c 3 8.8.8.8"
echo "  ip route get 8.8.8.8 from 10.174.38.1"
echo "  curl --interface 10.174.38.1 -sS https://ifconfig.co"

echo
echo "7) Примечания по IPv6:"
echo "  - NAT для IPv6 обычно не используют. Это значит, что для выхода по IPv6 нужно, чтобы провайдер/маршрутизатор знал о ваших префиксах."
echo "  - Если клиент получает адрес из fd67:... и внешний маршрутизатор не знает о вашем префиксе, IPv6-трафик не пойдёт."

echo
echo "Скрипт завершён. Если APPLY=1, команды были применены; если APPLY=0, вы увидели только что командах."
