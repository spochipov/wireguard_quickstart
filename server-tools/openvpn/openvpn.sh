#!/usr/bin/env bash
#
# OpenVPN setup and management script
# Directory: server-tools/openvpn/
#
# Описание и функциональность:
#  - Автоматическая установка OpenVPN + easy-rsa PKI (Debian/Ubuntu, apt; частичная поддержка yum)
#  - Генерация EC-сертификатов (easy-rsa, secp384r1) для сервера и клиентов
#  - Конфиг сервера настроен для максимальной пропускной способности:
#      * AES-256-GCM, ncp-ciphers (CHACHA20-POLY1305)
#      * Увеличенные сокет-буферы (sndbuf/rcvbuf) и sysctl (rmem/wmem, tcp_rmem/tcp_wmem)
#      * Попытка включить BBR congestion control
#  - Автоопределение внешнего интерфейса для правил NAT (EXT_IF вместо жесткого eth0)
#  - Автоматическая подстановка публичного IP в клиентский .ovpn (метаданные облаков + fallback)
#  - Управление клиентами: генерация, отзыв (CRL) и выдача .ovpn с inline сертификатами
#  - Интеграция iperf3: запуск сервера, запуск клиента, автотест + рекомендации по настройке
#
# Доступные команды:
#   ./openvpn.sh install
#       - Устанавливает пакеты, инициализирует PKI, создаёт конфиг сервера, применяет sysctl и правила iptables,
#         включает/перезапускает сервис OpenVPN.
#
#   ./openvpn.sh add-client <name>
#       - Генерирует клиентский ключ/сертификат, формирует единый .ovpn файл (включая <ca>, <cert>, <key>).
#       - Попытается автоматически подставить публичный IP вместо YOUR_SERVER_IP.
#       - Можно принудительно задать IP через переменную окружения PUBLIC_IP_OVERRIDE.
#
#   ./openvpn.sh revoke-client <name>
#       - Отзывает клиент, генерирует и копирует CRL в серверную директорию, перезапускает сервис.
#
#   ./openvpn.sh iperf-start
#       - Устанавливает iperf3 (если нужно) и запускает iperf3 сервер в фоне.
#
#   ./openvpn.sh iperf-test <target> [tcp|udp] [time_sec] [parallel_streams]
#       - Запускает iperf3 клиент к указанному таргету с параметрами.
#
#   ./openvpn.sh iperf-recommend <target>
#       - Выполняет iperf3 тест (TCP, 15s, 4 потокa), парсит Mbps и даёт рекомендации по sysctl/буферам/BBR/OPENVPN_SOCKBUF.
#
#   ./openvpn.sh help|--help|-h
#       - Показать эту справку.
#
# Принципы и замечания по безопасности/поддержке:
#  - Скрипт ориентирован на Debian/Ubuntu; для других дистрибутивов возможны отличия в путях и пакетах.
#  - Для корректной автоопределения публичного IP рекомендуется иметь curl/dig (dnsutils) установленные.
#  - tls-crypt/tls-auth и автоматическая установка значений по результатам iperf — опциональные функции, которые можно добавить дополнительно.
#
# Пример использования:
#   sudo ./openvpn.sh install
#   sudo ./openvpn.sh add-client alice
#   sudo ./openvpn.sh iperf-start
#   sudo ./openvpn.sh iperf-recommend <client-ip-or-vpn-ip>
#
set -euo pipefail

# Конфигурация (можно изменить перед вызовом)
OVPN_PORT=1194
OVPN_PROTO=udp
OVPN_DEV=tun
EASYRSA_DIR=/etc/openvpn/easy-rsa
SERVER_DIR=/etc/openvpn/server
OUTPUT_DIR=/root/openvpn-clients
VPN_NETWORK=10.8.0.0
VPN_NETMASK=255.255.255.0
DNS1=1.1.1.1
DNS2=8.8.8.8

# Performance tuning values
SYSCTL_SETTINGS=(
  "net.ipv4.ip_forward=1"
  "net.core.rmem_max=26214400"
  "net.core.wmem_max=26214400"
  "net.ipv4.tcp_rmem=4096 87380 16777216"
  "net.ipv4.tcp_wmem=4096 65536 16777216"
  "net.ipv4.tcp_congestion_control=bbr"
)
OPENVPN_SOCKBUF=131072

usage() {
  sed -n '1,120p' "$0" | sed -n '1,120p' >/dev/stdout
  echo
  echo "Пример:"
  echo "  sudo $0 install"
  echo "  sudo $0 add-client alice"
  echo "  sudo $0 revoke-client alice"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Требуются права root. Запустите: sudo $0 $*"
    exit 1
  fi
}

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}

apply_sysctl() {
  echo "Применяю sysctl настройки для производительности..."
  for s in "${SYSCTL_SETTINGS[@]}"; do
    key="${s%%=*}"
    val="${s#*=}"
    grep -q "^${key}=" /etc/sysctl.conf 2>/dev/null && \
      sed -i "s|^${key}=.*|${key}=${val}|" /etc/sysctl.conf || echo "${key}=${val}" >> /etc/sysctl.conf
    sysctl -w "${key}=${val}" >/dev/null || true
  done
  sysctl -p >/dev/null || true
}

install_packages_debian() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa iptables-persistent openssh-client >/dev/null
}

install_packages_yum() {
  yum install -y epel-release
  yum install -y openvpn easy-rsa iptables-services >/dev/null
}

setup_easy_rsa() {
  mkdir -p "${EASYRSA_DIR}"
  if [ ! -d "${EASYRSA_DIR}/.git" ]; then
    # Use system easy-rsa if available, otherwise copy from /usr/share/easy-rsa
    if [ -d /usr/share/easy-rsa ]; then
      cp -r /usr/share/easy-rsa/* "${EASYRSA_DIR}/"
    else
      echo "Easy-RSA not found in /usr/share/easy-rsa. Попытка установить через пакет..."
      # assume already installed
    fi
  fi
  chown -R root:root "${EASYRSA_DIR}"
  cd "${EASYRSA_DIR}"
  # Configure easy-rsa to use EC
  export EASYRSA_BATCH=1
  export EASYRSA_REQ_CN="OpenVPN-CA"
  echo "EASYRSA_ALGO=ec" > "${EASYRSA_DIR}/vars"
  echo "EASYRSA_CURVE=secp384r1" >> "${EASYRSA_DIR}/vars"
  # Init PKI if not exists
  if [ ! -d "${EASYRSA_DIR}/pki" ]; then
    ./easyrsa init-pki
    ./easyrsa --batch build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    ./easyrsa gen-crl

    # Generate DH params for compatibility with OpenVPN if not present (safe for EC)
    if [ ! -f "${EASYRSA_DIR}/pki/dh.pem" ]; then
      ./easyrsa gen-dh
    fi

    # Generate tls-crypt key for extra TLS handshake protection
    if [ ! -f "${EASYRSA_DIR}/pki/ta.key" ]; then
      # use openvpn to generate a static key if available, otherwise fallback to openssl
      if command -v openvpn >/dev/null 2>&1; then
        openvpn --genkey --secret "${EASYRSA_DIR}/pki/ta.key"
      else
        openssl rand -out "${EASYRSA_DIR}/pki/ta.key" 256 2>/dev/null || true
      fi
    fi
  fi
  # place files to server dir
  mkdir -p "${SERVER_DIR}"
  cp "${EASYRSA_DIR}/pki/ca.crt" "${SERVER_DIR}/"
  cp "${EASYRSA_DIR}/pki/private/server.key" "${SERVER_DIR}/"
  cp "${EASYRSA_DIR}/pki/issued/server.crt" "${SERVER_DIR}/"
  cp "${EASYRSA_DIR}/pki/crl.pem" "${SERVER_DIR}/crl.pem"
  # copy dh if generated
  if [ -f "${EASYRSA_DIR}/pki/dh.pem" ]; then
    cp "${EASYRSA_DIR}/pki/dh.pem" "${SERVER_DIR}/dh.pem"
  fi
  # copy tls-crypt key if generated
  if [ -f "${EASYRSA_DIR}/pki/ta.key" ]; then
    cp "${EASYRSA_DIR}/pki/ta.key" "${SERVER_DIR}/ta.key"
    chmod 600 "${SERVER_DIR}/ta.key" || true
  fi
  chmod 600 "${SERVER_DIR}/server.key" || true
}

write_server_conf() {
  mkdir -p "${SERVER_DIR}"
  cat > "${SERVER_DIR}/server.conf" <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev ${OVPN_DEV}
user nobody
group nogroup
persist-key
persist-tun
keepalive 10 120
topology subnet
server ${VPN_NETWORK} 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS1}"
push "dhcp-option DNS ${DNS2}"
# Cipher and performance
tls-server
tls-version-min 1.2
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
# Use explicit buffer sizes
sndbuf ${OPENVPN_SOCKBUF}
rcvbuf ${OPENVPN_SOCKBUF}
# Keep logs minimal
status /var/log/openvpn-status.log
verb 3
crl-verify ${SERVER_DIR}/crl.pem
ca ${SERVER_DIR}/ca.crt
cert ${SERVER_DIR}/server.crt
key ${SERVER_DIR}/server.key
dh ${SERVER_DIR}/dh.pem
tls-crypt ${SERVER_DIR}/ta.key
# Use ECDH params if available (easy-rsa handles ECDH internally)
# no explicit dh
EOF
}

setup_firewall() {
  echo "Настраиваю iptables NAT и правила..."
  # NAT rule
  # Determine external interface automatically (fallback to eth0)
  EXT_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
  if [ -z "${EXT_IF}" ]; then
    EXT_IF=eth0
  fi
  iptables -t nat -C POSTROUTING -s "${VPN_NETWORK}/24" -o "${EXT_IF}" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "${VPN_NETWORK}/24" -o "${EXT_IF}" -j MASQUERADE
  # Allow forwarding
  iptables -C FORWARD -s "${VPN_NETWORK}/24" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s "${VPN_NETWORK}/24" -j ACCEPT
  iptables -C FORWARD -d "${VPN_NETWORK}/24" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -d "${VPN_NETWORK}/24" -j ACCEPT

  # Save rules (Debian)
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
  elif command -v iptables-save >/dev/null 2>&1 && [ -w /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
}

enable_openvpn_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable openvpn-server@server.service || true
    systemctl restart openvpn-server@server.service || systemctl restart openvpn.service || true
  else
    service openvpn restart || true
  fi
}

install_iperf() {
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y iperf3 >/dev/null 2>&1 || true
  fi
}

start_iperf_server() {
  install_iperf
  if ! pgrep -x iperf3 >/dev/null 2>&1; then
    iperf3 -s -D >/dev/null 2>&1 || true
    echo "iperf3 server started (daemon)"
  else
    echo "iperf3 server already running"
  fi
}

# Run iperf3 client to target. Usage: run_iperf_client <target> [tcp|udp] [time_sec] [parallel_streams]
run_iperf_client() {
  local TARGET="$1"
  local PROTO="${2:-tcp}"
  local TIME="${3:-15}"
  local PAR="${4:-4}"
  install_iperf
  if [ "${PROTO}" = "udp" ]; then
    iperf3 -c "${TARGET}" -u -b 0 -t "${TIME}" -P "${PAR}"
  else
    iperf3 -c "${TARGET}" -t "${TIME}" -P "${PAR}"
  fi
}

# Run iperf3 client, parse throughput (Mbits/sec) and provide tuning recommendations.
run_iperf_and_recommend() {
  local TARGET="$1"
  local TMP="$(mktemp /tmp/iperf3.XXXXXX)"
  echo "Запускаю iperf3 тест к ${TARGET} (TCP, 15s, 4 потокa)..."
  install_iperf
  iperf3 -c "${TARGET}" -t 15 -P 4 > "${TMP}" 2>&1 || true

  # Try to extract Mbps value (look for 'Mbits/sec')
  MBPS=$(grep -Eo '[0-9]+(\.[0-9]+)? Mbits/sec' "${TMP}" | tail -n1 | awk '{print $1}')
  if [ -z "${MBPS}" ]; then
    echo "Не удалось определить пропускную способность из вывода iperf3. Покажу полный вывод:"
    sed -n '1,200p' "${TMP}"
    rm -f "${TMP}"
    return 1
  fi

  echo "Измеренная пропускная способность: ${MBPS} Mbits/sec"
  recommend_tuning "${MBPS}"
  rm -f "${TMP}"
}

recommend_tuning() {
  local MBPS="$1"
  local KBPS=$((MBPS * 1000))
  echo
  echo "Рекомендации по настройке (по результатам ${MBPS} Mbit/s):"
  if (( $(echo "${MBPS} >= 1000" | bc -l) )); then
    echo "- Для >1Gbps:"
    echo "  * net.core.rmem_max/wmem_max = 33554432"
    echo "  * net.ipv4.tcp_rmem = 4096 87380 16777216"
    echo "  * net.ipv4.tcp_wmem = 4096 65536 16777216"
    echo "  * Увеличить OPENVPN_SOCKBUF до 262144"
    echo "  * Включить BBR (net.ipv4.tcp_congestion_control=bbr) и перезагрузить"
  elif (( $(echo "${MBPS} >= 200" | bc -l) )); then
    echo "- Для 200-1000 Mbit/s:"
    echo "  * net.core.rmem_max/wmem_max = 16777216"
    echo "  * OPENVPN_SOCKBUF = 131072"
    echo "  * tcp_rmem/tcp_wmem оставить как в скрипте"
    echo "  * Попробовать iperf3 с -P 4..8 для более точной оценки"
  else
    echo "- Для <200 Mbit/s:"
    echo "  * Оставить значения по умолчанию или небольшие увеличения"
    echo "  * OPENVPN_SOCKBUF = 65536..131072"
    echo "  * Используйте несколько потоков (-P 2..4) для измерения"
  fi

  echo
  echo "Применение рекомендаций:"
  echo "  - Вы можете изменить массив SYSCTL_SETTINGS в скрипте и запустить install (apply_sysctl) или применить вручную с sysctl -w"
  echo "  - Чтобы изменить OPENVPN_SOCKBUF, скорректируйте переменную OPENVPN_SOCKBUF в начале скрипта и перезапустите OpenVPN"
}

generate_client() {
  local CN="$1"
  cd "${EASYRSA_DIR}"
  export EASYRSA_BATCH=1
  if [ ! -d "${EASYRSA_DIR}/pki" ]; then
    echo "PKI не инициализирован. Выполните 'install' сначала."
    exit 1
  fi
  # gen client keys
  ./easyrsa gen-req "${CN}" nopass
  ./easyrsa sign-req client "${CN}"

  mkdir -p "${OUTPUT_DIR}"
  local CLIENT_OVPN="${OUTPUT_DIR}/${CN}.ovpn"
  cat > "${CLIENT_OVPN}" <<EOF
client
dev ${OVPN_DEV}
proto ${OVPN_PROTO}
remote YOUR_SERVER_IP ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:CHACHA20-POLY1305
auth SHA256
verb 3
sndbuf ${OPENVPN_SOCKBUF}
rcvbuf ${OPENVPN_SOCKBUF}
setenv CLIENT_CERT 1
EOF

  # Append CA, cert, key
  echo "<ca>" >> "${CLIENT_OVPN}"
  cat "${EASYRSA_DIR}/pki/ca.crt" >> "${CLIENT_OVPN}"
  echo "</ca>" >> "${CLIENT_OVPN}"

  echo "<cert>" >> "${CLIENT_OVPN}"
  sed -n '/BEGIN/,/END/p' "${EASYRSA_DIR}/pki/issued/${CN}.crt" >> "${CLIENT_OVPN}"
  echo "</cert>" >> "${CLIENT_OVPN}"

  echo "<key>" >> "${CLIENT_OVPN}"
  sed -n '/BEGIN/,/END/p' "${EASYRSA_DIR}/pki/private/${CN}.key" >> "${CLIENT_OVPN}"
  echo "</key>" >> "${CLIENT_OVPN}"

  # Optional tls-auth or tls-crypt could be added here if desired
  # Embed tls-crypt key if exists
  if [ -f "${EASYRSA_DIR}/pki/ta.key" ]; then
    echo "<tls-crypt>" >> "${CLIENT_OVPN}"
    cat "${EASYRSA_DIR}/pki/ta.key" >> "${CLIENT_OVPN}"
    echo "</tls-crypt>" >> "${CLIENT_OVPN}"
  fi
  chmod 600 "${CLIENT_OVPN}"

  # Try to detect public IP to replace placeholder in client config.
  # You can override detection by setting PUBLIC_IP_OVERRIDE environment variable.
  PUBLIC_IP=""
  if [ -n "${PUBLIC_IP_OVERRIDE:-}" ]; then
    PUBLIC_IP="${PUBLIC_IP_OVERRIDE}"
  else
    # 1) Try common cloud metadata endpoints (fast, local link)
    if command -v curl >/dev/null 2>&1; then
      # AWS
      AWS_IP=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 || true)
      if [ -n "${AWS_IP}" ]; then PUBLIC_IP="${AWS_IP}"; fi

      # GCP (requires header)
      if [ -z "${PUBLIC_IP}" ]; then
        GCP_IP=$(curl -s --max-time 2 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || true)
        if [ -n "${GCP_IP}" ]; then PUBLIC_IP="${GCP_IP}"; fi
      fi

      # DigitalOcean
      if [ -z "${PUBLIC_IP}" ]; then
        DO_IP=$(curl -s --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)
        if [ -n "${DO_IP}" ]; then PUBLIC_IP="${DO_IP}"; fi
      fi

      # Hetzner
      if [ -z "${PUBLIC_IP}" ]; then
        HN_IP=$(curl -s --max-time 2 http://169.254.169.254/hetzner/v1/network/interfaces/0/ipv4/primary 2>/dev/null || true)
        if [ -n "${HN_IP}" ]; then PUBLIC_IP="${HN_IP}"; fi
      fi

      # OVH (some OVH images expose via 169.254 or via api.ovh; try metadata)
      if [ -z "${PUBLIC_IP}" ]; then
        OVH_IP=$(curl -s --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
        if [ -n "${OVH_IP}" ]; then PUBLIC_IP="${OVH_IP}"; fi
      fi
    fi

    # 2) If still empty, try to get the source IP used to reach internet (may be private)
    if [ -z "${PUBLIC_IP}" ]; then
      PUBLIC_IP=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7; exit}' || true)
    fi

    # 3) If that looks private or is empty, try resolver/service methods
    if [ -z "${PUBLIC_IP}" ] || echo "${PUBLIC_IP}" | grep -Eq '^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])|^192\.168\.'; then
      # try OpenDNS using dig
      if command -v dig >/dev/null 2>&1; then
        PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)
      fi
    fi

    if [ -z "${PUBLIC_IP}" ]; then
      # try https services (if curl available)
      if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP=$(curl -sS --max-time 4 https://ifconfig.co || true)
      fi
    fi

    if [ -z "${PUBLIC_IP}" ]; then
      if command -v curl >/dev/null 2>&1; then
        PUBLIC_IP=$(curl -sS --max-time 4 https://icanhazip.com || true)
      fi
    fi

    PUBLIC_IP=$(echo "${PUBLIC_IP}" | tr -d ' \t\n\r')
  fi

  if [ -n "${PUBLIC_IP}" ]; then
    # replace placeholder in generated ovpn
    sed -i "s|YOUR_SERVER_IP|${PUBLIC_IP}|g" "${CLIENT_OVPN}" || true
    echo "Автоматически подставлен IP: ${PUBLIC_IP} в ${CLIENT_OVPN}"
  else
    echo "Не удалось определить публичный IP. Оставлен YOUR_SERVER_IP в ${CLIENT_OVPN}"
    echo "Чтобы явно задать IP, экспортируйте PUBLIC_IP_OVERRIDE перед вызовом add-client."
  fi

  echo "Клиентский конфиг создан: ${CLIENT_OVPN}"
}

revoke_client() {
  local CN="$1"
  cd "${EASYRSA_DIR}"
  export EASYRSA_BATCH=1
  if [ ! -f "${EASYRSA_DIR}/pki/index.txt" ]; then
    echo "PKI не инициализирован."
    exit 1
  fi
  ./easyrsa --batch revoke "${CN}" || true
  ./easyrsa gen-crl
  cp "${EASYRSA_DIR}/pki/crl.pem" "${SERVER_DIR}/crl.pem"
  chmod 644 "${SERVER_DIR}/crl.pem"
  # update running server
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart openvpn-server@server.service || true
  fi
  echo "Клиент ${CN} отозван и CRL обновлён."
}

do_install() {
  ensure_root
  PKG_MGR=$(detect_package_manager)
  if [ "${PKG_MGR}" = "apt" ]; then
    install_packages_debian
  elif [ "${PKG_MGR}" = "yum" ]; then
    install_packages_yum
  else
    echo "Не удалось определить пакетный менеджер. Поддерживаются apt/yum."
    exit 1
  fi

  apply_sysctl
  setup_easy_rsa
  write_server_conf
  setup_firewall

  # Enable and start openvpn
  # Place server config in /etc/openvpn/server/server.conf (systemd expects this)
  mkdir -p /etc/openvpn/server
  cp "${SERVER_DIR}/server.conf" /etc/openvpn/server/server.conf
  cp "${SERVER_DIR}/server.crt" /etc/openvpn/server/
  cp "${SERVER_DIR}/server.key" /etc/openvpn/server/
  cp "${SERVER_DIR}/ca.crt" /etc/openvpn/server/
  cp "${SERVER_DIR}/crl.pem" /etc/openvpn/server/
  chmod 600 /etc/openvpn/server/server.key || true

  enable_openvpn_service

  echo "Установка завершена. Создайте клиентов: sudo $0 add-client <name>"
  echo "Клиентские конфиги будут в ${OUTPUT_DIR}"
}

main() {
  if [ $# -lt 1 ]; then
    usage
    exit 1
  fi

  cmd="$1"; shift || true

  case "${cmd}" in
    install)
      do_install
      ;;
    add-client)
      if [ $# -ne 1 ]; then
        echo "Укажите имя клиента: $0 add-client <name>"
        exit 1
      fi
      ensure_root
      generate_client "$1"
      ;;
    revoke-client)
      if [ $# -ne 1 ]; then
        echo "Укажите имя клиента: $0 revoke-client <name>"
        exit 1
      fi
      ensure_root
      revoke_client "$1"
      ;;
    iperf-start)
      # Запустить iperf3 сервер в фоне на текущей машине
      start_iperf_server
      ;;
    iperf-test)
      # Простой запуск iperf3 клиента: ./openvpn.sh iperf-test <target_ip> [tcp|udp] [time_sec] [parallel]
      if [ $# -lt 1 ]; then
        echo "Использование: $0 iperf-test <target> [tcp|udp] [time_sec] [parallel_streams]"
        exit 1
      fi
      run_iperf_client "$@"
      ;;
    iperf-recommend)
      # Запуск теста и вывод рекомендаций: ./openvpn.sh iperf-recommend <target>
      if [ $# -ne 1 ]; then
        echo "Использование: $0 iperf-recommend <target>"
        exit 1
      fi
      run_iperf_and_recommend "$1"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Неизвестная команда: ${cmd}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
