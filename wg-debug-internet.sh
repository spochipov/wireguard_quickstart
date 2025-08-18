#!/bin/bash

# WireGuard Internet Access Debug Script
# Comprehensive diagnostics for client internet connectivity issues

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

# Global variables
WG_CONF="/etc/wireguard/wg0.conf"
ISSUES_FOUND=0

check_wireguard_status() {
    section "WireGuard Service Status"
    
    if ! command -v wg >/dev/null 2>&1; then
        error "WireGuard tools not installed!"
        ((ISSUES_FOUND++))
        return
    fi
    
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        success "WireGuard service is running"
    else
        error "WireGuard service is not running!"
        echo "  Try: systemctl start wg-quick@wg0"
        ((ISSUES_FOUND++))
    fi
    
    if wg show wg0 >/dev/null 2>&1; then
        success "WireGuard interface wg0 is active"
        echo "Interface details:"
        wg show wg0
    else
        error "WireGuard interface wg0 is not active!"
        echo "  Try: wg-quick up wg0"
        ((ISSUES_FOUND++))
    fi
}

check_configuration_file() {
    section "Configuration File Analysis"
    
    if [ ! -f "$WG_CONF" ]; then
        error "WireGuard configuration file not found: $WG_CONF"
        ((ISSUES_FOUND++))
        return
    fi
    
    success "Configuration file exists: $WG_CONF"
    
    # Check for Table = off
    if grep -q "^Table = off" "$WG_CONF" 2>/dev/null; then
        error "CRITICAL: 'Table = off' found in server configuration!"
        echo "  This prevents automatic route creation and blocks internet access"
        echo "  Remove the line 'Table = off' from $WG_CONF"
        ((ISSUES_FOUND++))
    else
        success "No 'Table = off' directive found (good)"
    fi
    
    # Check server address
    if grep -q "^Address" "$WG_CONF"; then
        SERVER_ADDRESS=$(grep "^Address" "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')
        success "Server address configured: $SERVER_ADDRESS"
    else
        error "No server address configured!"
        ((ISSUES_FOUND++))
    fi
    
    # Check listen port
    if grep -q "^ListenPort" "$WG_CONF"; then
        LISTEN_PORT=$(grep "^ListenPort" "$WG_CONF" | cut -d'=' -f2 | tr -d ' ')
        success "Listen port configured: $LISTEN_PORT"
    else
        warn "No listen port specified (will use default 51820)"
    fi
    
    # Check for clients
    CLIENT_COUNT=$(grep -c "^\[Peer\]" "$WG_CONF" 2>/dev/null || echo "0")
    if [ "$CLIENT_COUNT" -gt 0 ]; then
        success "$CLIENT_COUNT client(s) configured"
    else
        warn "No clients configured yet"
    fi
}

check_network_interfaces() {
    section "Network Interface Configuration"
    
    # Check if wg0 interface exists and has IP
    if ip addr show wg0 >/dev/null 2>&1; then
        success "WireGuard interface wg0 exists"
        echo "Interface details:"
        ip addr show wg0 | grep -E "(inet|inet6)" || echo "  No IP addresses assigned"
    else
        error "WireGuard interface wg0 does not exist!"
        ((ISSUES_FOUND++))
    fi
    
    # Check default route interface
    DEFAULT_INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}' 2>/dev/null || echo "")
    if [ -n "$DEFAULT_INTERFACE" ]; then
        success "Default route interface: $DEFAULT_INTERFACE"
        
        # Check if default interface is up
        if ip link show "$DEFAULT_INTERFACE" | grep -q "state UP"; then
            success "Default interface $DEFAULT_INTERFACE is UP"
        else
            error "Default interface $DEFAULT_INTERFACE is DOWN!"
            ((ISSUES_FOUND++))
        fi
    else
        error "No default route found!"
        echo "  Check your network configuration"
        ((ISSUES_FOUND++))
    fi
}

check_ip_forwarding() {
    section "IP Forwarding Configuration"
    
    # Check IPv4 forwarding
    IPV4_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
    if [ "$IPV4_FORWARD" = "1" ]; then
        success "IPv4 forwarding is enabled"
    else
        error "IPv4 forwarding is DISABLED!"
        echo "  Enable with: echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
        echo "  Apply with: sysctl -p"
        ((ISSUES_FOUND++))
    fi
    
    # Check IPv6 forwarding
    IPV6_FORWARD=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo "0")
    if [ "$IPV6_FORWARD" = "1" ]; then
        success "IPv6 forwarding is enabled"
    else
        error "IPv6 forwarding is DISABLED!"
        echo "  Enable with: echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf"
        echo "  Apply with: sysctl -p"
        ((ISSUES_FOUND++))
    fi
}

check_firewall_rules() {
    section "Firewall and NAT Configuration"
    
    # Check if iptables is available
    if ! command -v iptables >/dev/null 2>&1; then
        error "iptables not found!"
        ((ISSUES_FOUND++))
        return
    fi
    
    # Check NAT rules
    echo "Checking NAT rules..."
    NAT_RULES=$(iptables -t nat -L POSTROUTING -n 2>/dev/null | grep MASQUERADE | wc -l || echo "0")
    if [ "$NAT_RULES" -gt 0 ]; then
        success "NAT/MASQUERADE rules found: $NAT_RULES"
        echo "NAT rules:"
        iptables -t nat -L POSTROUTING -n | grep MASQUERADE
    else
        error "No NAT/MASQUERADE rules found!"
        echo "  Clients won't be able to access internet without NAT"
        ((ISSUES_FOUND++))
    fi
    
    # Check FORWARD rules
    echo -e "\nChecking FORWARD rules..."
    FORWARD_ACCEPT=$(iptables -L FORWARD -n 2>/dev/null | grep "ACCEPT.*wg0" | wc -l || echo "0")
    if [ "$FORWARD_ACCEPT" -gt 0 ]; then
        success "FORWARD rules for wg0 found: $FORWARD_ACCEPT"
    else
        error "No FORWARD rules for wg0 found!"
        echo "  Add rules to allow traffic forwarding through wg0"
        ((ISSUES_FOUND++))
    fi
    
    # Check INPUT rules for WireGuard port
    LISTEN_PORT=$(grep "^ListenPort" "$WG_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "51820")
    INPUT_RULES=$(iptables -L INPUT -n 2>/dev/null | grep ":$LISTEN_PORT " | wc -l || echo "0")
    if [ "$INPUT_RULES" -gt 0 ]; then
        success "INPUT rule for WireGuard port $LISTEN_PORT found"
    else
        warn "No specific INPUT rule for WireGuard port $LISTEN_PORT"
        echo "  Consider adding: iptables -A INPUT -p udp --dport $LISTEN_PORT -j ACCEPT"
    fi
    
    # Show current iptables rules summary
    echo -e "\nCurrent iptables rules summary:"
    echo "NAT table:"
    iptables -t nat -L -n --line-numbers 2>/dev/null | head -20
    echo -e "\nFilter table (FORWARD chain):"
    iptables -L FORWARD -n --line-numbers 2>/dev/null | head -10
}

check_routing_table() {
    section "Routing Table Analysis"
    
    echo "IPv4 routing table:"
    ip route show
    
    echo -e "\nIPv6 routing table:"
    ip -6 route show 2>/dev/null || echo "IPv6 routing not available"
    
    # Check if there are routes for WireGuard network
    if [ -f "$WG_CONF" ] && grep -q "^Address" "$WG_CONF"; then
        WG_NETWORK=$(grep "^Address" "$WG_CONF" | cut -d'=' -f2 | tr -d ' ' | cut -d',' -f1 | cut -d'/' -f1)
        if [ -n "$WG_NETWORK" ]; then
            WG_NET_PREFIX=$(echo "$WG_NETWORK" | cut -d'.' -f1-3)
            if ip route show | grep -q "$WG_NET_PREFIX"; then
                success "Routes for WireGuard network found"
            else
                warn "No specific routes for WireGuard network $WG_NET_PREFIX.0/24"
            fi
        fi
    fi
}

check_dns_configuration() {
    section "DNS Configuration"
    
    # Check system DNS
    if [ -f /etc/resolv.conf ]; then
        echo "System DNS configuration (/etc/resolv.conf):"
        cat /etc/resolv.conf
        
        # Test DNS resolution
        echo -e "\nTesting DNS resolution..."
        if nslookup google.com >/dev/null 2>&1; then
            success "DNS resolution working"
        else
            error "DNS resolution failed!"
            echo "  Check your DNS configuration"
            ((ISSUES_FOUND++))
        fi
    else
        warn "/etc/resolv.conf not found"
    fi
    
    # Check if clients have DNS configured
    if [ -f "$WG_CONF" ]; then
        echo -e "\nChecking client DNS configuration..."
        if find /etc/wireguard/clients/ -name "*.conf" -exec grep -l "^DNS" {} \; 2>/dev/null | head -1 >/dev/null; then
            success "Client configurations have DNS settings"
            echo "Example client DNS:"
            find /etc/wireguard/clients/ -name "*.conf" -exec grep "^DNS" {} \; 2>/dev/null | head -1
        else
            warn "No DNS configuration found in client configs"
            echo "  Clients may not be able to resolve domain names"
        fi
    fi
}

check_connectivity() {
    section "Internet Connectivity Test"
    
    # Test connectivity from server
    echo "Testing connectivity from server..."
    
    if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
        success "Server can reach internet (ping 8.8.8.8)"
    else
        error "Server cannot reach internet!"
        echo "  Check your internet connection"
        ((ISSUES_FOUND++))
    fi
    
    if ping -c 3 google.com >/dev/null 2>&1; then
        success "Server can resolve and reach google.com"
    else
        error "Server cannot resolve/reach google.com!"
        echo "  Check DNS and internet connectivity"
        ((ISSUES_FOUND++))
    fi
    
    # Test from WireGuard interface if possible
    if ip addr show wg0 >/dev/null 2>&1; then
        WG_IP=$(ip addr show wg0 | grep "inet " | awk '{print $2}' | cut -d'/' -f1 | head -1)
        if [ -n "$WG_IP" ]; then
            echo -e "\nTesting from WireGuard interface ($WG_IP)..."
            if ping -I wg0 -c 3 8.8.8.8 >/dev/null 2>&1; then
                success "WireGuard interface can reach internet"
            else
                warn "WireGuard interface cannot reach internet directly"
                echo "  This might be normal depending on configuration"
            fi
        fi
    fi
}

check_client_connectivity() {
    section "Client Connectivity Analysis"
    
    if ! wg show wg0 >/dev/null 2>&1; then
        warn "WireGuard interface not active, skipping client analysis"
        return
    fi
    
    # Show connected clients
    echo "Currently connected clients:"
    wg show wg0 | grep -E "(peer|endpoint|latest handshake)" || echo "No active connections"
    
    # Check for recent handshakes
    echo -e "\nAnalyzing client connections..."
    ACTIVE_CLIENTS=0
    
    while IFS= read -r line; do
        if [[ $line =~ ^peer:\ (.+)$ ]]; then
            CURRENT_PEER="${BASH_REMATCH[1]}"
        elif [[ $line =~ latest\ handshake:\ (.+)$ ]]; then
            HANDSHAKE="${BASH_REMATCH[1]}"
            if [[ $HANDSHAKE != *"ago"* ]] || [[ $HANDSHAKE == *"seconds ago"* ]] || [[ $HANDSHAKE == *"minute"* ]]; then
                success "Client ${CURRENT_PEER:0:16}... has recent handshake: $HANDSHAKE"
                ((ACTIVE_CLIENTS++))
            else
                warn "Client ${CURRENT_PEER:0:16}... has old handshake: $HANDSHAKE"
            fi
        fi
    done < <(wg show wg0)
    
    if [ $ACTIVE_CLIENTS -gt 0 ]; then
        success "$ACTIVE_CLIENTS client(s) with recent activity"
    else
        warn "No clients with recent activity"
        echo "  Clients may not be connected or have connectivity issues"
    fi
}

check_common_issues() {
    section "Common Configuration Issues"
    
    # Check for conflicting services
    echo "Checking for conflicting services..."
    
    if systemctl is-active --quiet ufw 2>/dev/null; then
        warn "UFW firewall is active"
        echo "  UFW may block WireGuard traffic"
        echo "  Check: ufw status verbose"
    fi
    
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "FirewallD is active"
        echo "  FirewallD may block WireGuard traffic"
    fi
    
    # Check for multiple WireGuard interfaces
    WG_INTERFACES=$(ip link show | grep "wg[0-9]" | wc -l || echo "0")
    if [ "$WG_INTERFACES" -gt 1 ]; then
        warn "Multiple WireGuard interfaces detected: $WG_INTERFACES"
        echo "  This may cause routing conflicts"
        ip link show | grep "wg[0-9]"
    fi
    
    # Check system load
    LOAD_AVG=$(cat /proc/loadavg | awk '{print $1}')
    CPU_COUNT=$(nproc)
    if (( $(echo "$LOAD_AVG > $CPU_COUNT" | bc -l) )); then
        warn "High system load: $LOAD_AVG (CPUs: $CPU_COUNT)"
        echo "  High load may affect VPN performance"
    fi
    
    # Check available memory
    MEM_AVAILABLE=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$MEM_AVAILABLE" -lt 100 ]; then
        warn "Low available memory: ${MEM_AVAILABLE}MB"
        echo "  Low memory may affect VPN performance"
    fi
}

provide_solutions() {
    section "Recommended Solutions"
    
    if [ $ISSUES_FOUND -eq 0 ]; then
        success "No critical issues found! Your WireGuard server appears to be configured correctly."
        echo ""
        echo "If clients still can't access internet, check:"
        echo "• Client configuration (AllowedIPs should be 0.0.0.0/0, ::/0)"
        echo "• Client firewall settings"
        echo "• ISP blocking VPN traffic"
        echo "• Client DNS configuration"
        return
    fi
    
    echo "Found $ISSUES_FOUND issue(s) that may prevent internet access:"
    echo ""
    
    echo "Quick fix commands:"
    echo "# Enable IP forwarding"
    echo "echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf"
    echo "echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf"
    echo "sysctl -p"
    echo ""
    
    echo "# Add basic NAT rule (replace eth0 with your interface)"
    DEFAULT_INTERFACE=$(ip route | grep default | head -1 | awk '{print $5}' 2>/dev/null || echo "eth0")
    echo "iptables -t nat -A POSTROUTING -o $DEFAULT_INTERFACE -j MASQUERADE"
    echo ""
    
    echo "# Add FORWARD rules"
    echo "iptables -A FORWARD -i wg0 -j ACCEPT"
    echo "iptables -A FORWARD -o wg0 -j ACCEPT"
    echo ""
    
    echo "# Restart WireGuard"
    echo "systemctl restart wg-quick@wg0"
    echo ""
    
    echo "# Save iptables rules (Debian/Ubuntu)"
    echo "iptables-save > /etc/iptables/rules.v4"
    echo "ip6tables-save > /etc/iptables/rules.v6"
}

# Main execution
main() {
    echo -e "${CYAN}WireGuard Internet Access Debug Tool${NC}"
    echo -e "${CYAN}====================================${NC}"
    echo ""
    
    check_wireguard_status
    check_configuration_file
    check_network_interfaces
    check_ip_forwarding
    check_firewall_rules
    check_routing_table
    check_dns_configuration
    check_connectivity
    check_client_connectivity
    check_common_issues
    provide_solutions
    
    echo ""
    if [ $ISSUES_FOUND -eq 0 ]; then
        echo -e "${GREEN}✓ Diagnosis complete: No critical issues found${NC}"
    else
        echo -e "${RED}✗ Diagnosis complete: $ISSUES_FOUND issue(s) found${NC}"
        echo -e "${YELLOW}Please review the recommendations above${NC}"
    fi
    
    echo ""
    echo "For additional help:"
    echo "• Check logs: journalctl -u wg-quick@wg0 -f"
    echo "• Monitor connections: watch -n 1 'wg show wg0'"
    echo "• Test performance: ./wg-performance-test.sh"
}

# Run main function
main "$@"
