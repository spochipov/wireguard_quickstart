#!/bin/bash
# WireGuard: remove client script
# Version: 1.0
#
# Usage: sudo ./wg-remove-client.sh <client_name>
#
# Behavior:
# - Finds peer by comment line "# <client_name" in /etc/wireguard/wg0.conf
# - Extracts PublicKey and removes the peer block from wg0.conf (makes a backup)
# - Removes client's config file from /etc/wireguard/clients/<client_name>.conf (if exists)
# - Removes the peer from the running interface (wg) if interface is up
# - Reloads/syncs wg0 from disk config
#
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Ошибка: требуется root${NC}" >&2
    exit 1
fi

if [ $# -lt 1 ]; then
    echo -e "${RED}Ошибка: укажите имя клиента.${NC}" >&2
    echo "Usage: $0 <client_name>"
    exit 1
fi

CLIENT_NAME="$1"
WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/etc/wireguard/clients"
CLIENT_CONF="$CLIENT_DIR/$CLIENT_NAME.conf"

if [ ! -f "$WG_CONF" ]; then
    echo -e "${RED}Ошибка: $WG_CONF не найден.${NC}" >&2
    exit 1
fi

echo -e "${GREEN}› Удаление клиента: $CLIENT_NAME${NC}"

# Try to find PublicKey by searching for comment line "# <CLIENT_NAME"
# We search a few lines after the comment for the PublicKey line.
PUBLIC_KEY=$(grep -n -A5 -F "# $CLIENT_NAME" "$WG_CONF" 2>/dev/null | grep -m1 'PublicKey' | sed -E 's/.*=[[:space:]]*//') || true

# Fallback: if comment not present, try to find a peer block that mentions the client name anywhere
if [ -z "$PUBLIC_KEY" ]; then
    # attempt to find any comment that contains the client name (case sensitive)
    PUBLIC_KEY=$(grep -n -A5 -F "$CLIENT_NAME" "$WG_CONF" 2>/dev/null | grep -m1 'PublicKey' | sed -E 's/.*=[[:space:]]*//') || true
fi

if [ -z "$PUBLIC_KEY" ]; then
    echo -e "${YELLOW}Не найден public key для клиента '$CLIENT_NAME' в $WG_CONF.${NC}"
    echo "Проверьте вручную и удалите блок [Peer] из конфигурации, если необходимо."
    exit 1
fi

echo -e "${GREEN}Found public key: ${PUBLIC_KEY}${NC}"

# Backup the wg config before modifying
BACKUP="${WG_CONF}.bak.$(date +%s)"
cp "$WG_CONF" "$BACKUP"
echo -e "${GREEN}Backup created: $BACKUP${NC}"

# Remove the peer block containing the public key.
# Use paragraph mode: remove any blank-line-separated paragraph that contains the PublicKey.
awk -v pk="$PUBLIC_KEY" 'BEGIN{RS=""; ORS=RS} $0 ~ pk { next } { print }' "$WG_CONF" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "$WG_CONF"

echo -e "${GREEN}Peer block removed from $WG_CONF${NC}"

# Remove from running interface (if exists)
if command -v wg >/dev/null 2>&1 && ip link show wg0 >/dev/null 2>&1; then
    # Try to remove the peer from kernel config first
    if wg set wg0 peer "$PUBLIC_KEY" remove 2>/dev/null; then
        echo -e "${GREEN}Peer removed from running interface wg0.${NC}"
    else
        echo -e "${YELLOW}Не удалось удалить peer через 'wg set'. Возможно интерфейс не активен или peer отсутствует в kernel.${NC}"
    fi
fi

# Reload/sync interface to apply file changes (same logic as add script)
echo -e "${GREEN}› Синхронизация интерфейса wg0 с конфигурацией...${NC}"
if command -v systemctl >/dev/null && systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || echo -e "${YELLOW}Warning: syncconf failed (systemctl active).${NC}"
elif ip link show wg0 >/dev/null 2>&1; then
    wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || echo -e "${YELLOW}Warning: syncconf failed (ip link show wg0).${NC}"
else
    echo -e "${YELLOW}Интерфейс wg0 не активен. Запустите: wg-quick up wg0 для применения конфигурации.${NC}"
fi

# Remove client config file if present
if [ -f "$CLIENT_CONF" ]; then
    rm -f "$CLIENT_CONF"
    echo -e "${GREEN}Removed client config: $CLIENT_CONF${NC}"
else
    echo -e "${YELLOW}Клиентский файл $CLIENT_CONF не найден, пропускаю удаление.${NC}"
fi

echo -e "${GREEN}✓ Клиент '$CLIENT_NAME' успешно удалён из конфигурации.${NC}"
