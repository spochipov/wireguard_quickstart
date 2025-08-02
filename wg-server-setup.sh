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

# Download and install client management scripts
download_client_scripts() {
    log "Downloading client management scripts from GitHub..."
    
    local github_base_url="https://raw.githubusercontent.com/spochipov/wireguard_quickstart/main"
    local scripts=(
        "wg-add-client.sh:wg-add-client"
        "wg-remove-client.sh:wg-remove-client"
        "wg-list-clients.sh:wg-list-clients"
    )
    
    for script_info in "${scripts[@]}"; do
        local source_file="${script_info%:*}"
        local target_name="${script_info#*:}"
        local target_path="/usr/local/bin/$target_name"
        
        log "Downloading $source_file..."
        
        # Download script with retry logic
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            if wget -q --timeout=30 -O "$target_path" "$github_base_url/$source_file"; then
                chmod +x "$target_path"
                log "Successfully downloaded and installed $target_name"
                break
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    warn "Failed to download $source_file, retrying ($retry_count/$max_retries)..."
                    sleep 2
                else
                    error "Failed to download $source_file after $max_retries attempts"
                fi
            fi
        done
    done
    
    log "All client management scripts downloaded successfully"
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
    download_client_scripts
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
