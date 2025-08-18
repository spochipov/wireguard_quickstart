#!/bin/sh
# Собрать диагностические выводы для анализа (запускать от root)
# Сохраните и запустите:
#   chmod +x scripts/run-wg-diagnostics-and-collect.sh
#   sudo ./scripts/run-wg-diagnostics-and-collect.sh
#
# Скрипт выполнит обновлённую диагностику и снимет правила/маршруты,
# а также попытается выполнить исходящий запрос через интерфейс wg0.
#
OUT_DIR="/tmp/wg-diagnostics-$(date +%s)"
mkdir -p "$OUT_DIR"
echo "Сохранение выводов в $OUT_DIR"

echo
echo "=== 1) Запуск обновлённого диагностического скрипта ==="
echo "sudo ./wg-debug-internet.sh"
sudo ./wg-debug-internet.sh 2>&1 | tee "$OUT_DIR/wg-debug-internet.txt"

echo
echo "=== 2) Снимки правил (iptables, ip6tables) ==="
echo "sudo iptables-save"
sudo iptables-save 2>&1 | tee "$OUT_DIR/iptables-save.txt"

echo
echo "sudo ip6tables-save"
sudo ip6tables-save 2>&1 | tee "$OUT_DIR/ip6tables-save.txt"

echo
echo "=== 3) Если используется nftables (необязательно) ==="
echo "sudo nft list ruleset || true"
sudo nft list ruleset 2>&1 | tee "$OUT_DIR/nft-ruleset.txt" || true

echo
echo "=== 4) Подробно: таблицы iptables ==="
echo "sudo iptables -L INPUT -n --line-numbers"
sudo iptables -L INPUT -n --line-numbers 2>&1 | tee "$OUT_DIR/iptables-INPUT.txt"

echo
echo "sudo iptables -L FORWARD -n --line-numbers"
sudo iptables -L FORWARD -n --line-numbers 2>&1 | tee "$OUT_DIR/iptables-FORWARD.txt"

echo
echo "sudo iptables -t nat -L POSTROUTING -n --line-numbers"
sudo iptables -t nat -L POSTROUTING -n --line-numbers 2>&1 | tee "$OUT_DIR/iptables-nat-POSTROUTING.txt"

echo
echo "=== 5) Проверка маршрутизации / исходящего трафика с интерфейса wg0 ==="
echo "sudo ip route get 8.8.8.8 from 10.174.38.1"
sudo ip route get 8.8.8.8 from 10.174.38.1 2>&1 | tee "$OUT_DIR/ip-route-get.txt"

echo
echo "=== 6) Попытка выйти в интернет с адреса wg0 (curl) ==="
echo "curl --interface 10.174.38.1 -sS https://ifconfig.co || echo 'curl failed'"
curl --interface 10.174.38.1 -sS https://ifconfig.co 2>&1 | tee "$OUT_DIR/ifconfig-co.txt" || echo "curl failed" | tee -a "$OUT_DIR/ifconfig-co.txt"

echo
echo "=== Дополнительно: вывести текущие IP адреса интерфейсов и маршруты ==="
ip addr show | tee "$OUT_DIR/ip-addr.txt"
ip route show | tee "$OUT_DIR/ip-route.txt"
ip -6 route show 2>/dev/null | tee "$OUT_DIR/ip6-route.txt"

echo
echo "Сбор завершён. Все файлы сохранены в $OUT_DIR"
echo "Скопируйте содержимое каталогa и вставьте сюда (или прикрепите)."
