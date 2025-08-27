#!/bin/bash
# install-openvpn.sh
# Тестировано под Debian 12
set -euo pipefail

# --- НАСТРОЙКИ ПО УМОЛЧАНИЮ (можно менять) ---
VPN_PROTO_DEFAULT="udp"            # "udp" или "tcp"
VPN_PORT_DEFAULT="1194"            # порт для OpenVPN (для обхода блокировок можно указать 443/tcp)
VPN_NET="10.8.0.0 255.255.255.0"   # подсеть VPN
EASYRSA_DIR="/etc/openvpn/easy-rsa"
CLIENTS_DIR="/root/clients"
INTERFACE=""                       # будет спросено
SERVER_ADDRESS=""                  # IP/домен будет спросен, пойдет в .ovpn

# --- ФУНКЦИИ ---
pause() { read -rp "Нажмите Enter чтобы продолжить..."; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Запустите скрипт от root"
    exit 1
  fi
}

read_user() {
  read -rp "Укажите публичный IP или доменное имя сервера: " SERVER_ADDRESS
  read -rp "Интерфейс VPS для NAT (пример: eth0) [автоопределение]: " INTERFACE
  if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -4 route list 0/0 | awk '{print $5; exit}')
    echo "Определен интерфейс: $INTERFACE"
  fi
  read -rp "Протокол (udp/tcp) [${VPN_PROTO_DEFAULT}]: " VPN_PROTO
  VPN_PROTO=${VPN_PROTO:-$VPN_PROTO_DEFAULT}
  read -rp "Порт [${VPN_PORT_DEFAULT}]: " VPN_PORT
  VPN_PORT=${VPN_PORT:-$VPN_PORT_DEFAULT}
}

install_pkgs() {
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y openvpn easy-rsa iptables-persistent curl ca-certificates
  # stunnel опция (для TCP/443 TLS-обёртки)
  read -rp "Установить stunnel4 (опция для TLS-обертки, может помочь при блокировках)? (y/N): " st
  if [[ "${st,,}" == "y" ]]; then
    apt install -y stunnel4
    STUNNEL=yes
  else
    STUNNEL=no
  fi
}

setup_easy_rsa() {
  mkdir -p "$EASYRSA_DIR"
  cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR/"
  chown -R root:root "$EASYRSA_DIR"
  cd "$EASYRSA_DIR"
  ./easyrsa init-pki
  ./easyrsa --batch build-ca nopass
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey --secret ta.key
  cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/
}

write_server_conf() {
  cat > /etc/openvpn/server.conf <<EOF
port ${VPN_PORT}
proto ${VPN_PROTO}
dev tun
user nobody
group nogroup
persist-key
persist-tun
server ${VPN_NET}
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
keepalive 10 120
cipher AES-128-GCM
ncp-ciphers AES-128-GCM:AES-256-GCM
auth SHA256
tls-server
tls-version-min 1.2
tls-crypt /etc/openvpn/ta.key
ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh /etc/openvpn/dh.pem
status /var/log/openvpn-status.log
verb 3
# увеличить буферы для throughput
sndbuf 393216
rcvbuf 393216
push "sndbuf 393216"
push "rcvbuf 393216"
# уменьшить задержку на UDP (этот параметр полезен на многих системах)
tun-mtu 1500
fragment 0
mssfix 1450
EOF
}

enable_ip_forward_and_sysctl() {
  sysctl_conf="/etc/sysctl.d/99-openvpn-tweaks.conf"
  cat > "$sysctl_conf" <<EOF
net.ipv4.ip_forward=1
# TCP/IP tuning for better throughput (adjust if needed)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=250000
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system || true
  # enable bbr if available
  if modprobe tcp_bbr &>/dev/null || true; then
    echo "BBR module проброшен (если поддерживается ядром)"
  fi
}

setup_nat() {
  # Простая NAT правила через iptables
  iptables -t nat -A POSTROUTING -s ${VPN_NET%% *} -o "$INTERFACE" -j MASQUERADE
  iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  iptables -A FORWARD -s ${VPN_NET%% *} -j ACCEPT
  # Сохраняем правила
  netfilter-persistent save
}

enable_service() {
  systemctl enable --now openvpn-server@server.service || systemctl enable --now openvpn@server.service || systemctl restart openvpn
}

make_clients_dir_and_helper() {
  mkdir -p "$CLIENTS_DIR"
  cat > /root/add-client.sh <<'EOS'
#!/bin/bash
# Простой генератор .ovpn с встройкой cert/key/ta
set -euo pipefail
EASYRSA_DIR="/etc/openvpn/easy-rsa"
CLIENTS_DIR="/root/clients"
SERVER_ADDRESS_PLACEHOLDER=""
read -rp "Имя клиента (латиница, без пробелов): " CLIENT
read -rp "Публичный адрес сервера (IP или домен): " SERVER_ADDR
cd "$EASYRSA_DIR"
./easyrsa gen-req "$CLIENT" nopass
./easyrsa sign-req client "$CLIENT"
OUT="${CLIENTS_DIR}/${CLIENT}.ovpn"
cat > "$OUT" <<EOF
client
dev tun
proto ${VPN_PROTO}
remote ${SERVER_ADDR} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-128-GCM
auth SHA256
verb 3
tun-mtu 1500
EOF
echo "<ca>" >> "$OUT"
cat /etc/openvpn/ca.crt >> "$OUT"
echo "</ca>" >> "$OUT"
echo "<cert>" >> "$OUT"
sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "${EASYRSA_DIR}/pki/issued/${CLIENT}.crt" >> "$OUT"
echo "</cert>" >> "$OUT"
echo "<key>" >> "$OUT"
cat "${EASYRSA_DIR}/pki/private/${CLIENT}.key" >> "$OUT"
echo "</key>" >> "$OUT"
echo "<tls-crypt>" >> "$OUT"
cat /etc/openvpn/ta.key >> "$OUT"
echo "</tls-crypt>" >> "$OUT"
chmod 600 "$OUT"
echo "Создано: $OUT"
EOS
  chmod +x /root/add-client.sh
  echo "Генератор клиентов установлен: /root/add-client.sh"
}

maybe_setup_stunnel() {
  if [ "${STUNNEL:-no}" != "yes" ]; then
    return
  fi
  # Простой шаблон stunnel — опция: пробрасываем TCP 443 на локальный OpenVPN TCP порт
  cat > /etc/stunnel/stunnel.conf <<EOF
cert = /etc/ssl/certs/stunnel.pem
foreground = no
[openvpn]
accept = 443
connect = 127.0.0.1:${VPN_PORT}
EOF
  # Создаем самоподписанный cert для stunnel (можно заменить на реальный)
  openssl req -new -x509 -days 3650 -nodes -out /etc/ssl/certs/stunnel.pem -keyout /etc/ssl/certs/stunnel.pem -subj "/CN=stunnel"
  systemctl enable --now stunnel4
  echo "stunnel настроен и включён (пробрасывает 443 -> ${VPN_PORT})."
}

main() {
  require_root
  read_user
  install_pkgs
  setup_easy_rsa
  write_server_conf
  enable_ip_forward_and_sysctl
  setup_nat
  enable_service
  make_clients_dir_and_helper
  maybe_setup_stunnel
  echo "Готово. Клиентские .ovpn файлы можно создать через /root/add-client.sh"
  echo "Папка клиентов: ${CLIENTS_DIR}"
}
main "$@"