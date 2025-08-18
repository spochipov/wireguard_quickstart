#!/bin/bash

# WireGuard Client Management Script with IPv6 support
# Version: 2.4 - Fixed unmatched brace error and used heredoc for client config block

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: Must be run as root${NC}" >&2
    exit 1
fi

# Check arguments
if [ $# -lt 1 ]; then
    echo -e "${RED}Error: Missing client name argument.${NC}" >&2
    echo "Usage: $0 <client_name>"
    exit 1
fi

CLIENT_NAME="$1"
WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/etc/wireguard/clients"
CLIENT_CONF="$CLIENT_DIR/$CLIENT_NAME.conf"

# Ensure base configs exist
if [ ! -f "$WG_CONF" ]; then
    echo -e "${RED}Error: Configuration $WG_CONF not found.${NC}" >&2
    exit 1
fi

mkdir -p "$CLIENT_DIR"

# Check duplicate
if [ -f "$CLIENT_CONF" ]; then
    echo -e "${YELLOW}Warning: Client '$CLIENT_NAME' already exists!${NC}"
    echo "File: $CLIENT_CONF"
    exit 1
fi

echo -e "${GREEN}+ Adding new WireGuard client: $CLIENT_NAME${NC}"

# Read server config
# Read server private key and derive public key (robust parsing)
SERVER_PRIVATE_KEY=$(grep -E '^\s*PrivateKey\s*=' "$WG_CONF" | head -1 | sed -E 's/.*=[[:space:]]*//')
if [ -n "$SERVER_PRIVATE_KEY" ]; then
    SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
else
    echo -e "${YELLOW}Warning: Server private key not found in $WG_CONF${NC}"
    SERVER_PUBLIC_KEY=""
fi

# Parse ListenPort from server config in a robust way; default to 51820 if not found
SERVER_PORT=$(grep -E '^\s*ListenPort\s*=' "$WG_CONF" | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || true)
if ! echo "$SERVER_PORT" | grep -Eq '^[0-9]+$'; then
    SERVER_PORT=51820
fi

# Detect public IPv4 for Endpoint (IPv4 only)
echo -e "${GREEN}+ Detecting public IPv4...${NC}"

SERVER_IPV4=$(curl -4 -s https://ifconfig.co 2>/dev/null || echo "")

if [[ "$SERVER_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    SERVER_ENDPOINT_IP="$SERVER_IPV4"
else
    SERVER_ENDPOINT_IP="YOUR_SERVER_IP"
    echo -e "${YELLOW}Warning: Could not auto-detect external IPv4 address. Please set manually.${NC}"
fi

# Use IPv4 endpoint only
FORMATTED_ENDPOINT="$SERVER_ENDPOINT_IP"

echo -e "${GREEN}✓ Using Endpoint: $FORMATTED_ENDPOINT:$SERVER_PORT${NC}"

# Get server address block (robust parsing: remove masks, handle spaces)
ADDRESS_LINE=$(grep '^Address' "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')
if [[ "$ADDRESS_LINE" == *","* ]]; then
    IPV4_SERVER_RAW=$(echo "$ADDRESS_LINE" | cut -d',' -f1)
    IPV6_SERVER_RAW=$(echo "$ADDRESS_LINE" | cut -d',' -f2)
    # remove mask suffixes (/24, /64)
    IPV4_SERVER="${IPV4_SERVER_RAW%%/*}"
    IPV6_SERVER="${IPV6_SERVER_RAW%%/*}"
    IPV4_NETWORK=$(echo "$IPV4_SERVER" | cut -d'.' -f1-3)
    IPV6_NETWORK=$(echo "$IPV6_SERVER" | cut -d':' -f1-4)
    DUAL_STACK=true
else
    IPV4_SERVER_RAW="$ADDRESS_LINE"
    IPV4_SERVER="${IPV4_SERVER_RAW%%/*}"
    IPV4_NETWORK=$(echo "$IPV4_SERVER" | cut -d'.' -f1-3)
    DUAL_STACK=false
fi

# Find next available IPs (check AllowedIPs entries, more reliable)
CLIENT_IPV4=""
for i in {2..254}; do
    candidate="${IPV4_NETWORK}.$i"
    # Look for candidate in server config AllowedIPs or Address lines
    if ! grep -E -q "(AllowedIPs *=.*${candidate}(/32)?|${candidate}/24|${candidate}/32)" "$WG_CONF"; then
        CLIENT_IPV4="$candidate"
        break
    fi
done

if [ -z "$CLIENT_IPV4" ]; then
    echo -e "${RED}No available IPv4s in $IPV4_NETWORK.0/24${NC}"
    exit 1
fi

CLIENT_IPV6=""
if [ "$DUAL_STACK" = true ]; then
    for i in {2..65534}; do
        hex=$(printf "%x" "$i")
        candidate="${IPV6_NETWORK}::${hex}/128"
        if ! grep -q "$candidate" "$WG_CONF"; then
            CLIENT_IPV6="${IPV6_NETWORK}::${hex}"
            break
        fi
    done

    if [ -z "$CLIENT_IPV6" ]; then
        echo -e "${RED}No available IPv6s in $IPV6_NETWORK::/64${NC}"
        exit 1
    fi
fi

# Generate client keys
umask 077
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

echo "Generating client configuration..."

# Write client config using heredoc
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IPV4/24$( [ "$DUAL_STACK" = true ] && echo ", $CLIENT_IPV6/64" )
DNS = 1.1.1.1, 8.8.8.8$( [ "$DUAL_STACK" = true ] && echo ", 2606:4700:4700::1111, 2001:4860:4860::8888" )
MTU = 1500

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $FORMATTED_ENDPOINT:$SERVER_PORT
AllowedIPs = 0.0.0.0/0$( [ "$DUAL_STACK" = true ] && echo ", ::/0" )
PersistentKeepalive = 25
EOF

# Append to server config
{
    echo ""
    echo "[Peer]"
    if [ "$DUAL_STACK" = true ]; then
        echo "# $CLIENT_NAME (IPv4: $CLIENT_IPV4, IPv6: $CLIENT_IPV6)"
        echo "PublicKey = $CLIENT_PUBLIC_KEY"
        echo "AllowedIPs = $CLIENT_IPV4/32, $CLIENT_IPV6/128"
    else
        echo "# $CLIENT_NAME (IPv4: $CLIENT_IPV4)"
        echo "PublicKey = $CLIENT_PUBLIC_KEY"
        echo "AllowedIPs = $CLIENT_IPV4/32"
    fi
} >> "$WG_CONF"

# Reload WireGuard
echo -e "${GREEN}+ Reloading WireGuard interface wg0...${NC}"
if command -v systemctl >/dev/null && systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0)
elif ip link show wg0 >/dev/null 2>&1; then
    wg syncconf wg0 <(wg-quick strip wg0)
else
    echo -e "${YELLOW}Warning: Interface wg0 is not up. Try: wg-quick up wg0${NC}"
fi

# Show result
echo ""
echo -e "${GREEN}✓ Client '$CLIENT_NAME' added successfully.${NC}"
echo "IPv4: $CLIENT_IPV4/24"
[ "$DUAL_STACK" = true ] && echo "IPv6: $CLIENT_IPV6/64"
echo "Config: $CLIENT_CONF"

# Optional QR
if command -v qrencode >/dev/null; then
    echo ""
    echo "QR for mobile apps:"
    qrencode -t ansiutf8 < "$CLIENT_CONF"
else
    echo -e "${YELLOW}(qrencode not installed, skipping QR code)${NC}"
fi
