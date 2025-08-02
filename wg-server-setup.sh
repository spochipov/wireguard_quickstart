#!/bin/bash

# WireGuard Server Setup Script for Debian 12
# Supports IPv4 + IPv6, optimized for maximum throughput
# Author: Auto-generated script
# Version: 1.0

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
fi

# Check if running on Debian 12
if ! grep -q "Debian GNU/Linux 12" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Debian 12. Continuing anyway..."
fi

log "Starting WireGuard server setup..."

# Generate unique network ranges to avoid conflicts
# Using random subnets in private ranges
generate_unique_networks() {
    # Generate random IPv4 subnet (10.x.y.0/24 where x=100-199, y=0-255)
    local ipv4_second=$((100 + RANDOM % 100))
    local ipv4_third=$((RANDOM % 256))
    IPV4_NETWORK="10.${ipv4_second}.${ipv4_third}"
    IPV4_SERVER="${IPV4_NETWORK}.1"
    
    # Generate random IPv6 ULA subnet (fd00::/8)
    local ipv6_hex1=$(printf "%04x" $((RANDOM % 65536)))
    local ipv6_hex2=$(printf "%04x" $((RANDOM % 65536)))
    local ipv6_hex3=$(printf "%04x" $((RANDOM % 65536)))
    IPV6_NETWORK="fd${ipv6_hex1:0:2}:${ipv6_hex1:2:2}${ipv6_hex2:0:2}:${ipv6_hex2:2:2}${ipv6_hex3:0:2}:${ipv6_hex3:2:2}00"
    IPV6_SERVER="${IPV6_NETWORK}::1"
}

# Detect network interface
detect_interface() {
    INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
    if [ -z "$INTERFACE" ]; then
        error "Could not detect default network interface"
    fi
    log "Detected network interface: $INTERFACE"
}

# Update system and install packages
install_packages() {
    log "Updating system packages..."
    apt update
    
    log "Installing required packages..."
    apt install -y \
        wireguard \
        wireguard-tools \
        qrencode \
        iptables \
        iptables-persistent \
        netfilter-persistent \
        ufw \
        curl \
        wget \
        htop \
        iftop \
        net-tools \
        dnsutils
}

# Configure kernel parameters for maximum performance
optimize_kernel() {
    log "Optimizing kernel parameters for maximum throughput..."
    
    cat > /etc/sysctl.d/99-wireguard-performance.conf << 'EOF'
# IPv4 and IPv6 forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network performance optimizations
net.core.rmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_default = 262144
net.core.wmem_max = 16777216
net.core.netdev_max_backlog = 5000
net.core.netdev_budget = 600

# TCP optimizations
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# UDP optimizations
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# Connection tracking optimizations
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120

# IPv6 optimizations
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0
EOF

    sysctl -p /etc/sysctl.d/99-wireguard-performance.conf
    log "Kernel parameters optimized"
}

# Generate WireGuard keys
generate_keys() {
    log "Generating WireGuard keys..."
    
    umask 077
    mkdir -p /etc/wireguard/keys
    
    # Generate server keys
    wg genkey | tee /etc/wireguard/keys/server_private.key | wg pubkey > /etc/wireguard/keys/server_public.key
    
    SERVER_PRIVATE_KEY=$(cat /etc/wireguard/keys/server_private.key)
    SERVER_PUBLIC_KEY=$(cat /etc/wireguard/keys/server_public.key)
    
    log "Server keys generated successfully"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    
    # Reset UFW to defaults
    ufw --force reset
    
    # Set default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # Allow SSH (important!)
    ufw allow 22/tcp comment 'SSH'
    
    # Allow WireGuard
    ufw allow 51820/udp comment 'WireGuard'
    
    # Allow traffic from WireGuard clients
    ufw allow from ${IPV4_NETWORK}.0/24 comment 'WireGuard IPv4 clients'
    ufw allow from ${IPV6_NETWORK}::/64 comment 'WireGuard IPv6 clients'
    
    # Enable UFW
    ufw --force enable
    
    log "Firewall configured successfully"
}

# Configure iptables rules for NAT and forwarding
configure_iptables() {
    log "Configuring iptables rules..."
    
    # IPv4 rules
    iptables -t nat -A POSTROUTING -s ${IPV4_NETWORK}.0/24 -o $INTERFACE -j MASQUERADE
    iptables -A FORWARD -i wg0 -j ACCEPT
    iptables -A FORWARD -o wg0 -j ACCEPT
    
    # IPv6 rules
    ip6tables -t nat -A POSTROUTING -s ${IPV6_NETWORK}::/64 -o $INTERFACE -j MASQUERADE
    ip6tables -A FORWARD -i wg0 -j ACCEPT
    ip6tables -A FORWARD -o wg0 -j ACCEPT
    
    # Save rules
    netfilter-persistent save
    
    log "iptables rules configured and saved"
}

# Create WireGuard configuration
create_wg_config() {
    log "Creating WireGuard configuration..."
    
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
# Server configuration
Address = ${IPV4_SERVER}/24, ${IPV6_SERVER}/64
ListenPort = 51820
PrivateKey = $SERVER_PRIVATE_KEY

# Performance optimizations
MTU = 1420
Table = off

# Firewall rules
PostUp = iptables -t nat -A POSTROUTING -s ${IPV4_NETWORK}.0/24 -o $INTERFACE -j MASQUERADE
PostUp = ip6tables -t nat -A POSTROUTING -s ${IPV6_NETWORK}::/64 -o $INTERFACE -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = ip6tables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -j ACCEPT
PostUp = ip6tables -A FORWARD -o %i -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s ${IPV4_NETWORK}.0/24 -o $INTERFACE -j MASQUERADE
PostDown = ip6tables -t nat -D POSTROUTING -s ${IPV6_NETWORK}::/64 -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = ip6tables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -j ACCEPT
PostDown = ip6tables -D FORWARD -o %i -j ACCEPT

# Clients will be added below this line
EOF

    chmod 600 /etc/wireguard/wg0.conf
    log "WireGuard configuration created"
}

# Create client management scripts
create_client_scripts() {
    log "Creating client management scripts..."
    
    # Create add client script
    cat > /usr/local/bin/wg-add-client << 'EOF'
#!/bin/bash

# WireGuard Client Management Script with IPv6 support
# Usage: wg-add-client <client_name>
# Version: 2.0 - Updated for IPv4/IPv6 dual-stack support

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

CLIENT_NAME="${1:-}"
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
    echo "Please run the server setup script first."
    exit 1
fi

# Create clients directory
mkdir -p "$CLIENT_DIR"

# Check if client already exists
if [ -f "$CLIENT_CONF" ]; then
    echo -e "${YELLOW}Warning: Client '$CLIENT_NAME' already exists!${NC}"
    echo "Configuration file: $CLIENT_CONF"
    exit 1
fi

echo -e "${GREEN}Adding new WireGuard client: $CLIENT_NAME${NC}"

# Read server configuration
SERVER_PRIVATE_KEY=$(grep '^PrivateKey' "$WG_CONF" | cut -d' ' -f3)
SERVER_PUBLIC_KEY=$(echo "$SERVER_PRIVATE_KEY" | wg pubkey)
SERVER_PORT=$(grep '^ListenPort' "$WG_CONF" | cut -d' ' -f3)

# Get server endpoint (external IP)
SERVER_ENDPOINT=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "YOUR_SERVER_IP")
if [ "$SERVER_ENDPOINT" = "YOUR_SERVER_IP" ]; then
    echo -e "${YELLOW}Warning: Could not detect server IP automatically.${NC}"
    echo "Please manually replace 'YOUR_SERVER_IP' in the client config with your server's public IP."
fi

# Extract network information from server config
# Handle both single and dual-stack configurations
ADDRESS_LINE=$(grep '^Address' "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')

if [[ "$ADDRESS_LINE" == *","* ]]; then
    # Dual-stack configuration (IPv4, IPv6)
    IPV4_SERVER=$(echo "$ADDRESS_LINE" | cut -d',' -f1)
    IPV6_SERVER=$(echo "$ADDRESS_LINE" | cut -d',' -f2)
    IPV4_NETWORK=$(echo "$IPV4_SERVER" | cut -d'.' -f1-3)
    IPV6_NETWORK=$(echo "$IPV6_SERVER" | cut -d':' -f1-4)
    DUAL_STACK=true
else
    # IPv4 only configuration
    IPV4_SERVER="$ADDRESS_LINE"
    IPV4_NETWORK=$(echo "$IPV4_SERVER" | cut -d'.' -f1-3)
    DUAL_STACK=false
fi

# Find next available IPv4 address
CLIENT_IPV4=""
for i in {2..254}; do
    if ! grep -q "${IPV4_NETWORK}.$i/32" "$WG_CONF"; then
        CLIENT_IPV4="${IPV4_NETWORK}.$i"
        break
    fi
done

if [ -z "$CLIENT_IPV4" ]; then
    echo -e "${RED}Error: No available IPv4 addresses in range ${IPV4_NETWORK}.0/24!${NC}" >&2
    exit 1
fi

# Find next available IPv6 address (if dual-stack)
CLIENT_IPV6=""
if [ "$DUAL_STACK" = true ]; then
    for i in {2..65534}; do
        CLIENT_IPV6_HEX=$(printf "%x" $i)
        if ! grep -q "${IPV6_NETWORK}::${CLIENT_IPV6_HEX}/128" "$WG_CONF"; then
            CLIENT_IPV6="${IPV6_NETWORK}::${CLIENT_IPV6_HEX}"
            break
        fi
    done
    
    if [ -z "$CLIENT_IPV6" ]; then
        echo -e "${RED}Error: No available IPv6 addresses in range ${IPV6_NETWORK}::/64!${NC}" >&2
        exit 1
    fi
fi

# Generate client keys
umask 077
CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

# Create client configuration
echo "Generating client configuration..."

if [ "$DUAL_STACK" = true ]; then
    # Dual-stack client configuration
    cat > "$CLIENT_CONF" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IPV4/24, $CLIENT_IPV6/64
DNS = 8.8.8.8, 2001:4860:4860::8888, 1.1.1.1, 2606:4700:4700::1111
MTU = 1420

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # Add client to server configuration
    cat >> "$WG_CONF" << EOF

[Peer]
# Client: $CLIENT_NAME (IPv4: $CLIENT_IPV4, IPv6: $CLIENT_IPV6)
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IPV4/32, $CLIENT_IPV6/128
EOF

else
    # IPv4 only client configuration
    cat > "$CLIENT_CONF" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IPV4/24
DNS = 8.8.8.8, 1.1.1.1
MTU = 1420

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # Add client to server configuration
    cat >> "$WG_CONF" << EOF

[Peer]
# Client: $CLIENT_NAME (IPv4: $CLIENT_IPV4)
PublicKey = $CLIENT_PUBLIC_KEY
AllowedIPs = $CLIENT_IPV4/32
EOF

fi

# Reload WireGuard configuration
echo "Reloading WireGuard configuration..."
if systemctl is-active --quiet wg-quick@wg0; then
    wg syncconf wg0 <(wg-quick strip wg0)
else
    echo -e "${YELLOW}Warning: WireGuard service is not running. Starting it now...${NC}"
    systemctl start wg-quick@wg0
fi

# Success message
echo ""
echo -e "${GREEN}✓ Client '$CLIENT_NAME' added successfully!${NC}"
echo ""
echo "Client Information:"
echo "  Name: $CLIENT_NAME"
echo "  IPv4 Address: $CLIENT_IPV4/24"
if [ "$DUAL_STACK" = true ]; then
    echo "  IPv6 Address: $CLIENT_IPV6/64"
fi
echo "  Configuration file: $CLIENT_CONF"
echo ""

# Display QR code for mobile devices
echo "QR Code for mobile devices:"
qrencode -t ansiutf8 < "$CLIENT_CONF"
EOF

    chmod +x /usr/local/bin/wg-add-client

    # Create remove client script
    cat > /usr/local/bin/wg-remove-client << 'EOF'
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
EOF

    chmod +x /usr/local/bin/wg-remove-client

    # Create list clients script
    cat > /usr/local/bin/wg-list-clients << 'EOF'
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
EOF

    chmod +x /usr/local/bin/wg-list-clients
    
    log "Client management scripts created"
}

# Create server info script
create_info_script() {
    log "Creating server info script..."
    
    cat > /usr/local/bin/wg-server-info << EOF
#!/bin/bash

# WireGuard Server Information Script

echo "=== WireGuard Server Information ==="
echo "Server IPv4: ${IPV4_SERVER}/24"
echo "Server IPv6: ${IPV6_SERVER}/64"
echo "Network IPv4: ${IPV4_NETWORK}.0/24"
echo "Network IPv6: ${IPV6_NETWORK}::/64"
echo "Listen Port: 51820"
echo "Interface: $INTERFACE"
echo ""
echo "=== Active Connections ==="
wg show
echo ""
echo "=== Server Status ==="
systemctl status wg-quick@wg0 --no-pager
EOF

    chmod +x /usr/local/bin/wg-server-info
    log "Server info script created"
}

# Start and enable WireGuard
start_wireguard() {
    log "Starting WireGuard service..."
    
    systemctl enable wg-quick@wg0
    systemctl start wg-quick@wg0
    
    # Verify service is running
    if systemctl is-active --quiet wg-quick@wg0; then
        log "WireGuard service started successfully"
    else
        error "Failed to start WireGuard service"
    fi
}

# Create backup script
create_backup_script() {
    log "Creating backup script..."
    
    cat > /usr/local/bin/wg-backup << 'EOF'
#!/bin/bash

BACKUP_DIR="/root/wireguard-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/wireguard_backup_$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"

tar -czf "$BACKUP_FILE" \
    /etc/wireguard/ \
    /etc/sysctl.d/99-wireguard-performance.conf \
    /usr/local/bin/wg-add-client \
    /usr/local/bin/wg-server-info \
    /usr/local/bin/wg-backup

echo "Backup created: $BACKUP_FILE"

# Keep only last 10 backups
cd "$BACKUP_DIR"
ls -t wireguard_backup_*.tar.gz | tail -n +11 | xargs -r rm
EOF

    chmod +x /usr/local/bin/wg-backup
    log "Backup script created"
}

# Main execution
main() {
    log "=== WireGuard Server Setup Started ==="
    
    generate_unique_networks
    detect_interface
    install_packages
    optimize_kernel
    generate_keys
    configure_firewall
    configure_iptables
    create_wg_config
    create_client_scripts
    create_info_script
    create_backup_script
    start_wireguard
    
    log "=== Setup Complete ==="
    echo ""
    echo -e "${GREEN}WireGuard server setup completed successfully!${NC}"
    echo ""
    echo "Server Information:"
    echo "  IPv4 Network: ${IPV4_NETWORK}.0/24"
    echo "  IPv6 Network: ${IPV6_NETWORK}::/64"
    echo "  Server IPv4: ${IPV4_SERVER}"
    echo "  Server IPv6: ${IPV6_SERVER}"
    echo "  Interface: $INTERFACE"
    echo ""
    echo "Available commands:"
    echo "  wg-add-client <name>     - Add a new client"
    echo "  wg-remove-client <name>  - Remove a client"
    echo "  wg-list-clients          - List all clients and their status"
    echo "  wg-server-info           - Show server information"
    echo "  wg-backup               - Create configuration backup"
    echo "  wg show                 - Show active connections"
    echo ""
    echo "Configuration files:"
    echo "  Server: /etc/wireguard/wg0.conf"
    echo "  Clients: /etc/wireguard/clients/"
    echo ""
    echo -e "${YELLOW}Important: Save this network information for your records!${NC}"
    echo "IPv4: ${IPV4_NETWORK}.0/24"
    echo "IPv6: ${IPV6_NETWORK}::/64"
}

# Run main function
main "$@"
