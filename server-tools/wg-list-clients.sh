#!/bin/bash
# Simple wg-list-clients.sh
# Lists clients declared in /etc/wireguard/wg0.conf and shows active peers (wg show)
# Usage: sudo wg-list-clients.sh
set -euo pipefail

WG_CONF="/etc/wireguard/wg0.conf"

if [ ! -f "$WG_CONF" ]; then
  echo "WireGuard config not found: $WG_CONF"
  exit 1
fi

echo "=== Clients parsed from $WG_CONF ==="
awk '
/^\[Peer\]/{inpeer=1; next}
inpeer && /^#/ { name=substr($0,3); gsub(/^ +| +$/, "", name); next }
inpeer && /PublicKey/ { pk=$0; sub(/.*=[[:space:]]*/, "", pk); next }
inpeer && /AllowedIPs/ {
  ai=$0; sub(/.*=[[:space:]]*/, "", ai);
  # print: name | publickey | allowedips
  printf "%-30s | %-44s | %s\n", (name ? name : "<no-name>"), (pk ? pk : "<no-pubkey>"), ai;
  inpeer=0; name=""; pk=""; ai="";
}
' "$WG_CONF"

echo
echo "=== Active peers (wg show) ==="
if command -v wg >/dev/null 2>&1; then
  wg show
else
  echo "wg tool not installed or not in PATH"
fi
