#!/bin/sh
# Добавить явное INPUT правило для WireGuard (IPv4 + IPv6).
# Запускать от root.
# Dry-run (по умолчанию) — покажет команды, не применяя их.
# Для применения: ./scripts/add-wg-input-rule.sh apply
APPLY=0
if [ "$1" = "apply" ]; then
  APPLY=1
fi

WG_PORT=51820

run() {
  printf "+ %s\n" "$*"
  if [ "$APPLY" -eq 1 ]; then
    eval "$@"
  fi
}

echo "Добавление правила INPUT для WireGuard (порт $WG_PORT). APPLY=$APPLY"
echo

# 1) Попытка добавить правило в nftables (inet filter input)
if command -v nft >/dev/null 2>&1; then
  echo "Проверка nftables..."
  # Проверим, есть ли правило уже в ruleset
  if nft list ruleset 2>/dev/null | grep -q "udp dport $WG_PORT"; then
    echo "Правило для udp dport $WG_PORT найдено в nftables — пропускаем добавление."
  else
    # Попробуем добавить правило в таблицу inet filter input
    # Если таблицы/цепочки нет — создадим безопасно (проверяем существование)
    if nft list table inet filter >/dev/null 2>&1; then
      run nft add rule inet filter input udp dport $WG_PORT accept comment \"allow WireGuard\"
    else
      echo "Таблица 'inet filter' отсутствует. Создавать новую таблицу/цепочки не буду автоматически."
      echo "Если хотите — создайте таблицу и цепочки вручную или используйте iptables/ip6tables."
    fi
  fi
else
  echo "nft отсутствует — пропускаем шаг nftables."
fi

echo
# 2) iptables (IPv4)
if command -v iptables >/dev/null 2>&1; then
  echo "Проверка iptables (IPv4)..."
  if iptables -C INPUT -p udp --dport $WG_PORT -j ACCEPT >/dev/null 2>&1; then
    echo "iptables уже содержит правило INPUT для udp dport $WG_PORT"
  else
    run iptables -I INPUT 1 -p udp --dport $WG_PORT -m comment --comment "allow WireGuard" -j ACCEPT
  fi
else
  echo "iptables не найдено."
fi

echo
# 3) ip6tables (IPv6)
if command -v ip6tables >/dev/null 2>&1; then
  echo "Проверка ip6tables (IPv6)..."
  if ip6tables -C INPUT -p udp --dport $WG_PORT -j ACCEPT >/dev/null 2>&1; then
    echo "ip6tables уже содержит правило INPUT для udp dport $WG_PORT"
  else
    run ip6tables -I INPUT 1 -p udp --dport $WG_PORT -m comment --comment "allow WireGuard v6" -j ACCEPT
  fi
else
  echo "ip6tables не найдено."
fi

echo
echo "Готово. Рекомендуемые проверки после применения:"
echo "  iptables -L INPUT -n --line-numbers"
echo "  ip6tables -L INPUT -n --line-numbers"
echo "  nft list ruleset | sed -n '1,200p'  # если nft используется"
echo "  wg-debug-internet  # запустить анализ снова"
echo
if [ "$APPLY" -eq 0 ]; then
  echo "Для применения запустите: $0 apply"
fi
