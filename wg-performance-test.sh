#!/bin/bash

# WireGuard Performance Testing Script
# Tests network performance and provides optimization recommendations

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# Performance test functions
test_network_performance() {
    log "Testing network performance..."
    
    echo "=== Network Interface Information ==="
    ip addr show
    echo ""
    
    echo "=== WireGuard Status ==="
    if wg show wg0 >/dev/null 2>&1; then
        wg show wg0
    else
        warn "WireGuard interface wg0 is not active"
    fi
    echo ""
    
    echo "=== Current MTU Settings ==="
    if ip link show wg0 >/dev/null 2>&1; then
        echo "WireGuard MTU: $(ip link show wg0 | grep -o 'mtu [0-9]*' | cut -d' ' -f2)"
    fi
    
    # Get default interface
    DEFAULT_INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}')
    if [ -n "$DEFAULT_INTERFACE" ]; then
        echo "Default interface MTU: $(ip link show $DEFAULT_INTERFACE | grep -o 'mtu [0-9]*' | cut -d' ' -f2)"
    fi
    echo ""
}

test_kernel_parameters() {
    log "Checking kernel parameters..."
    
    echo "=== Network Buffer Settings ==="
    echo "net.core.rmem_max: $(sysctl -n net.core.rmem_max 2>/dev/null || echo 'N/A')"
    echo "net.core.wmem_max: $(sysctl -n net.core.wmem_max 2>/dev/null || echo 'N/A')"
    echo "net.core.netdev_max_backlog: $(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 'N/A')"
    echo ""
    
    echo "=== TCP Settings ==="
    echo "net.ipv4.tcp_congestion_control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
    echo "net.ipv4.tcp_window_scaling: $(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null || echo 'N/A')"
    echo ""
    
    echo "=== UDP Settings ==="
    echo "net.ipv4.udp_rmem_min: $(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || echo 'N/A')"
    echo "net.ipv4.udp_wmem_min: $(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null || echo 'N/A')"
    echo ""
}

test_connection_speed() {
    log "Testing connection speeds..."
    
    echo "=== Internet Speed Test (without VPN) ==="
    if command -v curl >/dev/null; then
        echo "Testing download speed..."
        curl -w "Download Speed: %{speed_download} bytes/sec\nTotal Time: %{time_total} seconds\n" \
             -o /dev/null -s "http://speedtest.wdc01.softlayer.com/downloads/test10.zip" 2>/dev/null || \
        echo "Speed test failed - server may be unavailable"
    else
        warn "curl not available for speed testing"
    fi
    echo ""
}

test_wireguard_throughput() {
    log "Testing WireGuard throughput..."
    
    if ! wg show wg0 >/dev/null 2>&1; then
        warn "WireGuard interface not active, skipping throughput test"
        return
    fi
    
    echo "=== WireGuard Interface Statistics ==="
    wg show wg0 dump 2>/dev/null || echo "No peer statistics available"
    echo ""
    
    echo "=== Network Interface Statistics ==="
    if command -v iftop >/dev/null; then
        echo "iftop available for real-time monitoring"
    fi
    
    if [ -f /proc/net/dev ]; then
        echo "Interface statistics from /proc/net/dev:"
        grep -E "(wg0|$(ip route | grep default | head -1 | awk '{print $5}'))" /proc/net/dev || true
    fi
    echo ""
}

check_cpu_usage() {
    log "Checking CPU usage..."
    
    echo "=== CPU Information ==="
    if [ -f /proc/cpuinfo ]; then
        echo "CPU cores: $(nproc)"
        echo "CPU model: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
    fi
    echo ""
    
    echo "=== Current Load ==="
    if command -v top >/dev/null; then
        top -bn1 | head -5
    elif [ -f /proc/loadavg ]; then
        echo "Load average: $(cat /proc/loadavg)"
    fi
    echo ""
}

provide_recommendations() {
    log "Providing performance recommendations..."
    
    echo "=== Performance Optimization Recommendations ==="
    echo ""
    
    # Check MTU
    if ip link show wg0 >/dev/null 2>&1; then
        WG_MTU=$(ip link show wg0 | grep -o 'mtu [0-9]*' | cut -d' ' -f2)
        if [ "$WG_MTU" -lt 1500 ]; then
            echo "• Consider increasing WireGuard MTU to 1500 for better performance"
            echo "  Current MTU: $WG_MTU"
        else
            echo "✓ WireGuard MTU is optimized ($WG_MTU)"
        fi
    fi
    echo ""
    
    # Check routing table
    if ip link show wg0 >/dev/null 2>&1; then
        echo "=== Routing Configuration Check ==="
        if grep -q "Table = off" /etc/wireguard/wg0.conf 2>/dev/null; then
            echo "⚠ WARNING: 'Table = off' found in server config!"
            echo "  This prevents automatic route creation and may block internet access"
            echo "  Remove 'Table = off' from /etc/wireguard/wg0.conf"
        else
            echo "✓ Routing table configuration is correct"
        fi
        echo ""
    fi
    
    # Check kernel parameters
    BBR_ENABLED=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$BBR_ENABLED" != "bbr" ]; then
        echo "• Enable BBR congestion control for better TCP performance:"
        echo "  echo 'net.ipv4.tcp_congestion_control = bbr' >> /etc/sysctl.conf"
    else
        echo "✓ BBR congestion control is enabled"
    fi
    echo ""
    
    # Check buffer sizes
    RMEM_MAX=$(sysctl -n net.core.rmem_max 2>/dev/null || echo "0")
    if [ "$RMEM_MAX" -lt 134217728 ]; then
        echo "• Increase network buffer sizes for high-throughput connections"
        echo "  Current rmem_max: $RMEM_MAX (recommended: 134217728)"
    else
        echo "✓ Network buffer sizes are optimized"
    fi
    echo ""
    
    # Check forwarding
    IPV4_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    IPV6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "0")
    
    if [ "$IPV4_FORWARD" != "1" ]; then
        echo "⚠ IPv4 forwarding is disabled! Enable with:"
        echo "  echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
    else
        echo "✓ IPv4 forwarding is enabled"
    fi
    
    if [ "$IPV6_FORWARD" != "1" ]; then
        echo "⚠ IPv6 forwarding is disabled! Enable with:"
        echo "  echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf"
    else
        echo "✓ IPv6 forwarding is enabled"
    fi
    echo ""
    
    echo "=== Additional Recommendations ==="
    echo "• Use fast DNS servers (1.1.1.1, 8.8.8.8) in client configs"
    echo "• Enable hardware acceleration if available (AES-NI)"
    echo "• Consider using UDP port 53 or 443 if behind restrictive firewalls"
    echo "• Monitor with: watch -n 1 'wg show wg0'"
    echo "• Test real-world performance with: iperf3 or speedtest-cli"
    echo "• Verify internet access: ping 8.8.8.8 from client"
    echo ""
}

run_bandwidth_test() {
    log "Running bandwidth test..."
    
    if command -v iperf3 >/dev/null; then
        echo "=== iperf3 Available ==="
        echo "To test bandwidth between client and server:"
        echo "Server: iperf3 -s"
        echo "Client: iperf3 -c <server_wg_ip>"
    else
        echo "=== Install iperf3 for detailed bandwidth testing ==="
        echo "apt install iperf3"
    fi
    echo ""
    
    if command -v speedtest-cli >/dev/null; then
        echo "Running speedtest-cli..."
        speedtest-cli --simple 2>/dev/null || echo "Speedtest failed"
    else
        echo "Install speedtest-cli for internet speed testing:"
        echo "apt install speedtest-cli"
    fi
    echo ""
}

# Main execution
main() {
    echo -e "${BLUE}=== WireGuard Performance Test Started ===${NC}"
    echo ""
    
    test_network_performance
    test_kernel_parameters
    test_connection_speed
    test_wireguard_throughput
    check_cpu_usage
    run_bandwidth_test
    provide_recommendations
    
    echo -e "${BLUE}=== Performance Test Complete ===${NC}"
    echo ""
    echo "For continuous monitoring, use:"
    echo "  watch -n 1 'wg show wg0'"
    echo "  iftop -i wg0"
    echo "  htop"
    echo ""
}

# Run main function
main "$@"
