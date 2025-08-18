#!/bin/bash
# change-wg-port.sh
# Сменить ListenPort в /etc/wireguard/wg0.conf, обновить правила firewall и перезапустить WireGuard.
#
# Использование:
#   sudo ./scripts/change-wg-port.sh 51821
#
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"
BIN_TARGET="/usr/local/bin/change-wg-port"

usage() {
  echo "Usage: $0 <new_port>"
  echo "Example: sudo $0 51821"
  exit 1
}

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root"
  exit 1
fi

if [ $# -ne 1 ]; then
  usage
fi

NEW_PORT="$1"
if ! echo "$NEW_PORT" | grep -Eq '^[0-9]+$' || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
  echo "Invalid port: $NEW_PORT"
  exit 1
fi

if [ ! -f "$WG_CONF" ]; then
  echo "WireGuard config not found: $WG_CONF"
  exit 1
fi

# Read current ListenPort (if any)
CURRENT_PORT=$(grep -E "^ListenPort" "$WG_CONF" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || echo "")

if [ "$CURRENT_PORT" = "$NEW_PORT" ]; then
  echo "ListenPort is already set to $NEW_PORT — nothing to do."
  exit 0
fi

echo "Changing WireGuard ListenPort: ${CURRENT_PORT:-(none)} -> $NEW_PORT"

# Backup config
cp "$WG_CONF" "${WG_CONF}.bak.$(date +%s)"
echo "Backup saved to ${WG_CONF}.bak.$(date +%s)"

# Update or add ListenPort
if grep -qE "^ListenPort" "$WG_CONF"; then
  sed -i "s/^ListenPort.*/ListenPort = $NEW_PORT/" "$WG_CONF"
else
  # insert below [Interface]
  awk -v port="$NEW_PORT" 'BEGIN{added=0} /^\[Interface\]/{print; getline; print; print "ListenPort = " port; added=1; next} {print} END{ if(!added) print "[Interface]\nListenPort = " port}' "$WG_CONF" > "${WG_CONF}.tmp" && mv "${WG_CONF}.tmp" "$WG_CONF"
fi
echo "Updated $WG_CONF"

# Firewall: add new INPUT rules and remove old ones (both iptables and ip6tables if present)
echo "Updating firewall rules..."

# Helper to delete rules for a given port (iptables)
delete_rules_for_port() {
  local table="$1"   # iptables or ip6tables
  local port="$2"
  if command -v "$table" >/dev/null 2>&1; then
    # iterate over all matching rules from save output and delete them
    if "$table"-save 2>/dev/null | grep -- "--dport $port" >/dev/null 2>&1; then
      # For each matching rule line, build a deletion command
      "$table"-save 2>/dev/null | grep -- "--dport $port" | while IFS= read -r line; do
        # convert '-A INPUT ...' to deletion command
        del_cmd=$(printf "%s" "$line" | sed -E 's/^-A ([^ ]+) /'"$table"' -D \1 /')
        echo "Deleting rule: $del_cmd"
        # ignore errors
        eval "$del_cmd" || true
      done
    fi
  fi
}

# Add rule for a port if not present (iptables)
add_rule_if_missing() {
  local table="$1"
  local proto="$2"
  local port="$3"
  local comment="$4"
  if command -v "$table" >/dev/null 2>&1; then
    if ! "$table" -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; then
      echo "Adding $table INPUT rule for $proto dport $port"
      "$table" -I INPUT 1 -p "$proto" --dport "$port" -m comment --comment "$comment" -j ACCEPT || "$table" -I INPUT 1 -p "$proto" --dport "$port" -j ACCEPT
    else
      echo "$table INPUT rule for $proto dport $port already exists"
    fi
  fi
}

# Remove old rules for CURRENT_PORT (if set)
if [ -n "$CURRENT_PORT" ]; then
  echo "Removing old iptables rules for port $CURRENT_PORT (if any)"
  delete_rules_for_port iptables "$CURRENT_PORT"
  delete_rules_for_port ip6tables "$CURRENT_PORT"
fi

# Add new rules
add_rule_if_missing iptables udp "$NEW_PORT" "allow WireGuard"
add_rule_if_missing ip6tables udp "$NEW_PORT" "allow WireGuard v6"

# Try to update common firewall managers (ufw, firewalld) as well
update_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status >/dev/null 2>&1; then
      echo "Updating UFW rules..."
      # Add new port rule
      ufw allow "${NEW_PORT}/udp" >/dev/null 2>&1 || true
      # Remove old port rule if present
      if [ -n "$CURRENT_PORT" ]; then
        ufw delete allow "${CURRENT_PORT}/udp" >/dev/null 2>&1 || true
      fi
      echo "UFW updated (allowed ${NEW_PORT}/udp)."
    fi
  fi
}

update_firewalld() {
  if command -v firewall-cmd >/dev/null 2>&1; then
    # Only act if firewalld is running
    if systemctl is-active --quiet firewalld 2>/dev/null; then
      echo "Updating firewalld rules..."
      firewall-cmd --permanent --add-port="${NEW_PORT}/udp" >/dev/null 2>&1 || true
      if [ -n "$CURRENT_PORT" ]; then
        firewall-cmd --permanent --remove-port="${CURRENT_PORT}/udp" >/dev/null 2>&1 || true
      fi
      firewall-cmd --reload >/dev/null 2>&1 || true
      echo "firewalld updated (added ${NEW_PORT}/udp)."
    fi
  fi
}

# Update nftables-managed rules (iptables-nft compatibility): no-op (we updated via iptables commands)
# Restart WireGuard to apply new ListenPort
echo "Restarting WireGuard..."
if command -v systemctl >/dev/null 2>&1 && systemctl --version >/dev/null 2>&1; then
  systemctl restart wg-quick@wg0 || (echo "systemctl restart failed, trying wg-quick" && wg-quick down wg0 >/dev/null 2>&1 || true; wg-quick up wg0)
else
  wg-quick down wg0 >/dev/null 2>&1 || true
  wg-quick up wg0
fi

# Save iptables rules if possible
if [ -d /etc/iptables ]; then
  iptables-save > /etc/iptables/rules.v4 || true
fi
if command -v ip6tables-save >/dev/null 2>&1 && [ -d /etc/iptables ]; then
  ip6tables-save > /etc/iptables/rules.v6 || true
fi

# Attempt to save via netfilter-persistent if available
if command -v netfilter-persistent >/dev/null 2>&1; then
  echo "Saving rules with netfilter-persistent..."
  netfilter-persistent save >/dev/null 2>&1 || true
elif command -v service >/dev/null 2>&1 && service netfilter-persistent save >/dev/null 2>&1; then
  service netfilter-persistent save >/dev/null 2>&1 || true
else
  echo "netfilter-persistent not found — rules saved to /etc/iptables if directory exists."
fi

# Update UFW/firewalld if present
update_ufw || true
update_firewalld || true

echo "ListenPort changed to $NEW_PORT and firewall updated."
echo "You can now run: wg show wg0"
 +++++++ REPLACE
