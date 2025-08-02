#!/bin/bash

# WireGuard Client Removal Script
# Usage: wg-remove-client <client_name>
# Version: 1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}" >&2
    exit 1
fi

CLIENT_NAME="$1"
if [ -z "$CLIENT_NAME" ]; then
    echo "Usage: $0 <client_name>"
    echo "Example: $0 laptop-john"
    exit 1
fi

WG_CONF="/etc/wireguard/wg0.conf"
CLIENT_DIR="/etc/wireguard/clients"
CLIENT_CONF="$CLIENT_DIR/$CLIENT_NAME.conf"

# Check if WireGuard config exists
if [ ! -f "$WG_CONF" ]; then
    echo -e "${RED}Error: WireGuard configuration not found at $WG_CONF${NC}" >&2
    exit 1
fi

# Check if client exists
if [ ! -f "$CLIENT_CONF" ]; then
    echo -e "${RED}Error: Client '$CLIENT_NAME' not found!${NC}" >&2
    echo "Available clients:"
    ls -1 "$CLIENT_DIR"/*.conf 2>/dev/null | xargs -n1 basename | sed 's/.conf$//' || echo "No clients found"
    exit 1
fi

echo -e "${YELLOW}Removing WireGuard client: $CLIENT_NAME${NC}"

# Get client's public key from config file
CLIENT_PUBLIC_KEY=$(grep '^PublicKey' "$CLIENT_CONF" | cut -d' ' -f3)

if [ -z "$CLIENT_PUBLIC_KEY" ]; then
    echo -e "${RED}Error: Could not find client's public key in $CLIENT_CONF${NC}" >&2
    exit 1
fi

echo "Client public key: $CLIENT_PUBLIC_KEY"

# Create temporary config without the client
TEMP_CONF=$(mktemp)
trap "rm -f $TEMP_CONF" EXIT

# Copy everything except the client's peer section
awk -v pubkey="$CLIENT_PUBLIC_KEY" '
BEGIN { skip = 0 }
/^\[Peer\]/ { 
    peer_section = ""
    skip = 0
    # Read the entire peer section
    while ((getline line) > 0) {
        peer_section = peer_section line "\n"
        if (line ~ /^$/ || line ~ /^\[/) {
            # End of peer section
            if (peer_section !~ pubkey) {
                # This peer is not the one we want to remove
                print "[Peer]"
                printf "%s", peer_section
            }
            if (line ~ /^\[/) {
                # Start of new section, print it
                print line
            }
            break
        }
    }
    next
}
{ print }
' "$WG_CONF" > "$TEMP_CONF"

# Backup original config
cp "$WG_CONF" "$WG_CONF.backup.$(date +%Y%m%d_%H%M%S)"

# Replace original config with cleaned version
mv "$TEMP_CONF" "$WG_CONF"
chmod 600 "$WG_CONF"

# Remove client configuration file
rm -f "$CLIENT_CONF"

# Reload WireGuard configuration
echo "Reloading WireGuard configuration..."
if systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0)
else
    echo -e "${YELLOW}Warning: WireGuard service is not running.${NC}"
fi

# Success message
echo ""
echo -e "${GREEN}✓ Client '$CLIENT_NAME' removed successfully!${NC}"
echo ""
echo "Actions performed:"
echo "  - Removed client from server configuration"
echo "  - Deleted client configuration file: $CLIENT_CONF"
echo "  - Created backup: $WG_CONF.backup.$(date +%Y%m%d_%H%M%S)"
echo "  - Reloaded WireGuard configuration"
echo ""
echo "Current active connections:"
wg show wg0 2>/dev/null || echo "No active connections"
