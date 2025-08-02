#!/bin/bash

# WireGuard Client List Script
# Usage: wg-list-clients
# Version: 1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}" >&2
    exit 1
fi

WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/etc/wireguard/clients"

# Check if WireGuard config exists
if [ ! -f "$WG_CONF" ]; then
    echo -e "${RED}Error: WireGuard configuration not found at $WG_CONF${NC}" >&2
    exit 1
fi

echo -e "${BLUE}=== WireGuard Server Status ===${NC}"
echo ""

# Server information
SERVER_ADDRESS=$(grep '^Address' "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')
SERVER_PORT=$(grep '^ListenPort' "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')
SERVER_ENDPOINT=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "Unknown")

echo -e "${CYAN}Server Information:${NC}"
echo "  Address: $SERVER_ADDRESS"
echo "  Port: $SERVER_PORT"
echo "  Public IP: $SERVER_ENDPOINT"
echo ""

# Check if clients directory exists
if [ ! -d "$CLIENT_DIR" ]; then
    echo -e "${YELLOW}No clients directory found${NC}"
    exit 0
fi

# Count clients
CLIENT_COUNT=$(ls -1 "$CLIENT_DIR"/*.conf 2>/dev/null | wc -l)

if [ "$CLIENT_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}No clients configured${NC}"
    echo ""
    echo "To add a client, run: wg-add-client <client_name>"
    exit 0
fi

echo -e "${CYAN}Configured Clients ($CLIENT_COUNT):${NC}"
echo ""

# Table header
printf "%-20s %-15s %-25s %-10s %-15s\n" "Client Name" "IPv4 Address" "IPv6 Address" "Status" "Last Handshake"
printf "%-20s %-15s %-25s %-10s %-15s\n" "────────────" "───────────" "─────────────" "──────" "──────────────"

# Get active connections info
WG_STATUS=$(wg show wg0 2>/dev/null || echo "")

# Process each client
for client_file in "$CLIENT_DIR"/*.conf; do
    if [ ! -f "$client_file" ]; then
        continue
    fi
    
    client_name=$(basename "$client_file" .conf)
    
    # Extract client information
    client_ipv4=$(grep '^Address' "$client_file" | cut -d'=' -f2 | tr -d ' ' | cut -d',' -f1 | cut -d'/' -f1)
    client_ipv6=""
    
    # Check if IPv6 is configured
    address_line=$(grep '^Address' "$client_file" | cut -d'=' -f2 | tr -d ' ')
    if [[ "$address_line" == *","* ]]; then
        client_ipv6=$(echo "$address_line" | cut -d',' -f2 | cut -d'/' -f1)
    fi
    
    client_pubkey=$(grep '^PublicKey' "$client_file" | cut -d'=' -f2 | tr -d ' ')
    
    # Check if client is currently connected
    status="Offline"
    last_handshake="Never"
    
    if echo "$WG_STATUS" | grep -q "$client_pubkey"; then
        # Extract handshake info for this client
        handshake_info=$(echo "$WG_STATUS" | awk -v pubkey="$client_pubkey" '
            $0 ~ pubkey { found=1; next }
            found && /latest handshake:/ { 
                gsub(/^[[:space:]]*latest handshake:[[:space:]]*/, "")
                print $0
                found=0
            }
            found && /^peer:/ { found=0 }
        ')
        
        if [ -n "$handshake_info" ]; then
            status="${GREEN}Online${NC}"
            last_handshake="$handshake_info"
        else
            status="${YELLOW}Connected${NC}"
        fi
    else
        status="${RED}Offline${NC}"
    fi
    
    # Format IPv6 for display (truncate if too long)
    if [ -n "$client_ipv6" ]; then
        if [ ${#client_ipv6} -gt 23 ]; then
            client_ipv6_display="${client_ipv6:0:20}..."
        else
            client_ipv6_display="$client_ipv6"
        fi
    else
        client_ipv6_display="N/A"
    fi
    
    # Format last handshake (truncate if too long)
    if [ ${#last_handshake} -gt 13 ]; then
        last_handshake_display="${last_handshake:0:10}..."
    else
        last_handshake_display="$last_handshake"
    fi
    
    printf "%-20s %-15s %-25s %-18s %-15s\n" \
        "$client_name" \
        "$client_ipv4" \
        "$client_ipv6_display" \
        "$status" \
        "$last_handshake_display"
done

echo ""

# Show active connections summary
active_count=$(echo "$WG_STATUS" | grep -c "^peer:" 2>/dev/null || echo "0")
echo -e "${CYAN}Connection Summary:${NC}"
echo "  Total clients: $CLIENT_COUNT"
echo "  Active connections: $active_count"

# Show bandwidth usage if available
if [ -n "$WG_STATUS" ] && echo "$WG_STATUS" | grep -q "transfer:"; then
    echo ""
    echo -e "${CYAN}Bandwidth Usage:${NC}"
    echo "$WG_STATUS" | awk '
    /^peer:/ { peer = $2 }
    /transfer:/ { 
        gsub(/,/, "", $2)
        gsub(/,/, "", $4)
        printf "  %s: ↓%s ↑%s\n", substr(peer,1,16) "...", $2, $4
    }'
fi

echo ""
echo -e "${CYAN}Management Commands:${NC}"
echo "  wg-add-client <name>     - Add new client"
echo "  wg-remove-client <name>  - Remove client"
echo "  wg-server-info          - Show server details"
echo "  wg show                 - Show detailed status"
