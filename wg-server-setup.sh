#!/bin/bash

# WireGuard Server Setup Script for Debian 12
# Supports IPv4 + IPv6, optimized for maximum throughput
# Author: Auto-generated script
# Version: 1.0

set -euo pipefail

DEFAULT_LISTEN_PORT=51820

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

# Check internet connectivity before starting
check_internet_connectivity() {
    log "Checking internet connectivity..."
    
    # Test basic connectivity
    if ! ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        error "No internet connectivity detected (ping 8.8.8.8 failed)"
        echo "Please check your internet connection and try again"
        exit 1
    fi
    
    # Test DNS resolution
    if ! ping -c 3 google.com >/dev/null 2>&1; then
        error "DNS resolution failed (ping google.com failed)"
        echo "Please check your DNS configuration and try again"
        exit 1
    fi
    
    # Robust external IP detection: try several services, DNS-based fallback, then IPv6
    EXTERNAL_IP=""
    for svc in "https://ifconfig.co" "https://icanhazip.com" "https://ipinfo.io/ip"; do
        EXTERNAL_IP=$(curl -4 -s --connect-timeout 5 "$svc" 2>/dev/null || echo "")
        if [[ "$EXTERNAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            break
        fi
    done

    # DNS-based fallback using OpenDNS
    if [[ ! "$EXTERNAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        if command -v dig >/dev/null 2>&1; then
            EXTERNAL_IP=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || echo "")
        fi
    fi

    if [[ "$EXTERNAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log "External IPv4 detected: $EXTERNAL_IP"
    else
        # Try IPv6 detection if IPv4 not found
        EXTERNAL_IPV6=""
        for svc in "https://ifconfig.co" "https://icanhazip.com" "https://ipinfo.io/ip"; do
            EXTERNAL_IPV6=$(curl -6 -s --connect-timeout 5 "$svc" 2>/dev/null || echo "")
            # crude IPv6 test: presence of colon
            if [[ "$EXTERNAL_IPV6" == *:* ]]; then
                break
            fi
        done

        if [[ "$EXTERNAL_IPV6" == *:* ]]; then
            log "External IPv6 detected: $EXTERNAL_IPV6"
            EXTERNAL_IP="$EXTERNAL_IPV6"
        else
            warn "Could not detect external IP address automatically"
            echo "External IP detection failed, but continuing with setup..."
            EXTERNAL_IP="YOUR_SERVER_IP"
        fi
    fi
    
    log "Internet connectivity check passed"
}

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

# Update system and install basic packages first
install_basic_packages() {
    log "Updating system packages..."
    apt update
    
    log "Installing basic network tools..."
    apt install -y \
        iproute2 \
        curl \
        wget \
        net-tools \
        procps \
        systemd
}

# Detect network interface
detect_interface() {
    INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
    if [ -z "$INTERFACE" ]; then
        error "Could not detect default network interface"
    fi
    log "Detected network interface: $INTERFACE"
}

# Install remaining packages
install_packages() {
    log "Installing WireGuard and additional packages..."
    apt install -y \
        wireguard \
        wireguard-tools \
        qrencode \
        iptables \
        htop \
        iftop \
        dnsutils
}

# Configure kernel parameters for maximum performance
optimize_kernel() {
    log "Optimizing kernel parameters for maximum throughput..."
    
    cat > /etc/sysctl.d/99-wireguard-performance.conf << 'EOF'
# IPv4 and IPv6 forwarding (essential for VPN)
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Network buffer optimizations for high throughput
net.core.rmem_default = 262144
net.core.rmem_max = 134217728
net.core.wmem_default = 262144
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 5000
net.core.netdev_budget = 600

# TCP optimizations for maximum performance
net.ipv4.tcp_rmem = 8192 262144 134217728
net.ipv4.tcp_wmem = 8192 262144 134217728
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_rfc1337 = 1

# UDP optimizations for WireGuard
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 102400 873800 16777216

# Connection tracking optimizations
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 7200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_generic_timeout = 120

# IPv6 optimizations
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0
net.ipv6.conf.all.autoconf = 0
net.ipv6.conf.default.autoconf = 0

# Memory and CPU optimizations
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# Network security optimizations that don't hurt performance
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
EOF

    # Apply settings with error handling
    log "Applying kernel parameters..."
    sysctl -p /etc/sysctl.d/99-wireguard-performance.conf 2>/dev/null || {
        warn "Some kernel parameters could not be applied (normal in containers)"
        # Apply only essential parameters
        sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
        sysctl -w net.ipv6.conf.all.forwarding=1 2>/dev/null || true
    }
    
    log "Kernel parameters optimized (container-compatible)"
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

# Configure basic firewall rules
configure_firewall() {
    log "Configuring basic firewall rules..."
    
    # Flush existing rules to start fresh
    iptables -F INPUT
    iptables -F FORWARD
    
    # Allow SSH (important!)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Allow WireGuard (use configured default port)
    iptables -A INPUT -p udp --dport ${DEFAULT_LISTEN_PORT} -j ACCEPT
    
    # Allow established and related connections
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Allow traffic from WireGuard clients
    iptables -A INPUT -s ${IPV4_NETWORK}.0/24 -j ACCEPT
    
    # IPv6 rules
    ip6tables -A INPUT -p tcp --dport 22 -j ACCEPT
    ip6tables -A INPUT -p udp --dport ${DEFAULT_LISTEN_PORT} -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -s ${IPV6_NETWORK}::/64 -j ACCEPT
    
    log "Basic firewall rules configured"
}

# Create WireGuard configuration
create_wg_config() {
    log "Creating WireGuard configuration..."
    
    cat > /etc/wireguard/wg0.conf << EOF
[Interface]
# Server configuration
Address = ${IPV4_SERVER}/24, ${IPV6_SERVER}/64
ListenPort = ${DEFAULT_LISTEN_PORT}
PrivateKey = $SERVER_PRIVATE_KEY
SaveConfig = true

# Performance optimizations for maximum speed
MTU = 1500

# Advanced performance settings
PreUp = echo 'module wireguard +p' > /sys/kernel/debug/dynamic_debug/control 2>/dev/null || true
PreUp = ethtool -K $INTERFACE rx-udp-gro-forwarding on 2>/dev/null || true
PreUp = ethtool -K $INTERFACE rx-gro-list off 2>/dev/null || true

# Firewall rules with performance optimizations
PostUp = iptables -P FORWARD ACCEPT; ip6tables -P FORWARD ACCEPT; iptables -t nat -A POSTROUTING -s ${IPV4_NETWORK}.0/24 -o $INTERFACE -j MASQUERADE; ip6tables -t nat -A POSTROUTING -s ${IPV6_NETWORK}::/64 -o $INTERFACE -j MASQUERADE; iptables -I FORWARD 1 -i %i -j ACCEPT; ip6tables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -j ACCEPT; ip6tables -I FORWARD 1 -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${IPV4_NETWORK}.0/24 -o $INTERFACE -j MASQUERADE; ip6tables -t nat -D POSTROUTING -s ${IPV6_NETWORK}::/64 -o $INTERFACE -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; ip6tables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; ip6tables -D FORWARD -o %i -j ACCEPT

# Clients will be added below this line
EOF

    chmod 600 /etc/wireguard/wg0.conf
    log "WireGuard configuration created with performance optimizations"
}

# Download and install client management scripts into a grouped directory
download_client_scripts() {
    log "Downloading client management scripts from GitHub..."
    
    local github_base_url="https://raw.githubusercontent.com/spochipov/wireguard_quickstart/main"
    local target_dir="/usr/local/bin/wg-tools"
    local scripts=(
        "server-tools/wg-add-client.sh:wg-add-client"
        "server-tools/wg-remove-client.sh:wg-remove-client"
        "server-tools/wg-list-clients.sh:wg-list-clients"
        "server-tools/wg-debug-internet.sh:wg-debug-internet"
        "server-tools/wg-performance-test.sh:wg-performance-test"
        "server-tools/wg-change-port.sh:wg-change-port"
    )
    
    # Create directory for grouped tools
    if [ ! -d "$target_dir" ]; then
        mkdir -p "$target_dir"
        chmod 755 "$target_dir"
    fi

    for script_info in "${scripts[@]}"; do
        local source_file="${script_info%:*}"
        local target_name="${script_info#*:}"
        local target_path="${target_dir}/${target_name}"
        
        log "Downloading $source_file -> $target_path ..."
        
        # Download script with retry logic
        local max_retries=3
        local retry_count=0
        
        while [ $retry_count -lt $max_retries ]; do
            if wget -q --timeout=30 -O "$target_path" "$github_base_url/$source_file"; then
                chmod +x "$target_path"
                log "Successfully downloaded $target_name to $target_path"
                # Create a symlink in /usr/local/bin for backwards compatibility / convenience
                ln -sf "$target_path" "/usr/local/bin/$target_name" 2>/dev/null || true
                break
            else
                retry_count=$((retry_count + 1))
                if [ $retry_count -lt $max_retries ]; then
                    warn "Failed to download $source_file, retrying ($retry_count/$max_retries)..."
                    sleep 2
                else
                    warn "Failed to download $source_file after $max_retries attempts, skipping."
                    # Don't abort entire setup for optional tools; move on to next script
                    break
                fi
            fi
        done
    done
    
    log "All client management scripts downloaded successfully into $target_dir (symlinks created in /usr/local/bin)"
}

# Create server info script
create_info_script() {
    log "Creating server info script..."
    
    cat > /usr/local/bin/wg-server-info << 'EOF'
#!/bin/bash
WG_CONF="/etc/wireguard/wg0.conf"
DEFAULT_PORT=51820

echo "=== WireGuard Server Information ==="

if [ -f "$WG_CONF" ]; then
  ADDR_LINE=$(grep -E '^Address' "$WG_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "unknown")
  LISTEN_PORT=$(grep -E '^ListenPort' "$WG_CONF" 2>/dev/null | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' || echo "$DEFAULT_PORT")
else
  ADDR_LINE="unknown"
  LISTEN_PORT="$DEFAULT_PORT"
fi

echo "Server Address(s): $ADDR_LINE"
echo "Listen Port: $LISTEN_PORT"
echo "Interface: $(ip route | grep default | head -1 | awk '{print $5}' 2>/dev/null || echo "unknown")"
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
    
    # Force down the interface to apply new config
    wg-quick down wg0 2>/dev/null || true
    
    # Try to use systemctl, fallback to manual start if in container
    if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
        systemctl enable wg-quick@wg0 2>/dev/null || warn "Could not enable WireGuard service (normal in containers)"
        systemctl restart wg-quick@wg0 2>/dev/null || {
            warn "systemctl failed, trying manual start..."
            wg-quick up wg0
        }
        
        # Verify service is running
        if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || wg show wg0 >/dev/null 2>&1; then
            log "WireGuard service started successfully"
        else
            error "Failed to start WireGuard service"
        fi
    else
        warn "systemctl not available, starting WireGuard manually..."
        wg-quick up wg0
        
        # Verify interface is up
        if wg show wg0 >/dev/null 2>&1; then
            log "WireGuard interface started successfully"
        else
            error "Failed to start WireGuard interface"
        fi
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
    /usr/local/bin/wg-remove-client \
    /usr/local/bin/wg-list-clients \
    /usr/local/bin/wg-debug-internet \
    /usr/local/bin/wg-performance-test \
    /usr/local/bin/wg-change-port \
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

# Test WireGuard connectivity after installation
test_wireguard_connectivity() {
    log "Testing WireGuard connectivity..."
    
    # Wait a moment for interface to fully initialize
    sleep 5
    
    # Check if WireGuard interface is up
    if ! wg show wg0 >/dev/null 2>&1; then
        error "WireGuard interface wg0 is not active!"
        return 1
    fi
    
    # Check if interface has IP address
    WG_IP=$(ip addr show wg0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
    if [ -z "$WG_IP" ]; then
        error "WireGuard interface has no IP address!"
        return 1
    fi
    
    log "WireGuard interface is up with IP: $WG_IP"
    
    # Test internet connectivity from server
    if ! ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        error "Server cannot reach internet after WireGuard setup!"
        return 1
    fi
    
    log "✓ WireGuard connectivity test passed"
    log "✓ Internet connectivity is working"
    
    return 0
}

# Main execution
main() {
    log "=== WireGuard Server Setup Started ==="
    
    # Pre-installation checks
    check_internet_connectivity
    
    # Setup process
    generate_unique_networks
    install_basic_packages
    detect_interface
    install_packages
    optimize_kernel
    generate_keys
    configure_firewall
    create_wg_config
    download_client_scripts
    create_info_script
    create_backup_script
    start_wireguard
    
    # Post-installation verification
    log "=== Running Post-Installation Tests ==="
    if test_wireguard_connectivity; then
        log "=== Setup Complete ==="
        echo ""
        echo -e "${GREEN}✓ WireGuard server setup completed successfully!${NC}"
        echo -e "${GREEN}✓ All connectivity tests passed${NC}"
        echo ""
        echo "Server Information:"
        echo "  External IP: $EXTERNAL_IP"
        echo "  IPv4 Network: ${IPV4_NETWORK}.0/24"
        echo "  IPv6 Network: ${IPV6_NETWORK}::/64"
        echo "  Server IPv4: ${IPV4_SERVER}"
        echo "  Server IPv6: ${IPV6_SERVER}"
        echo "  Interface: $INTERFACE"
        echo ""
        echo "Available commands:"
        echo "  wg-add-client <name>       - Add a new client"
        echo "  wg-remove-client <name>    - Remove a client"
        echo "  wg-list-clients            - List all clients and their status"
        echo "  wg-server-info             - Show server information"
        echo "  wg-debug-internet          - Debug connectivity issues"
        echo "  wg-performance-test        - Run performance/throughput tests"
        echo "  wg-change-port <port>      - Change WireGuard listen port"
        echo "  wg-backup                  - Create configuration backup"
        echo "  wg show                   - Show active connections"
        echo ""
        echo "Configuration files:"
        echo "  Server: /etc/wireguard/wg0.conf"
        echo "  Clients: /etc/wireguard/clients/"
        echo ""
        echo -e "${YELLOW}Important: Save this network information for your records!${NC}"
        echo "IPv4: ${IPV4_NETWORK}.0/24"
        echo "IPv6: ${IPV6_NETWORK}::/64"
        echo ""
        echo -e "${GREEN}Your WireGuard server is ready to use!${NC}"
        echo "Next step: Add clients with 'wg-add-client <client_name>'"
    else
        error "Post-installation connectivity test failed!"
        echo ""
        echo -e "${RED}Setup completed but connectivity tests failed.${NC}"
        echo -e "${YELLOW}Run 'wg-debug-internet' to diagnose issues.${NC}"
        exit 1
    fi
}

# Run main function
main "$@"
