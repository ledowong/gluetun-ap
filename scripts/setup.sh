#!/usr/bin/env bash
# Bootstrap the AP→VPN setup on Raspberry Pi OS (run as root).
set -euo pipefail

AP_IFACE="${AP_IFACE:-wlan0}"
AP_CIDR="${AP_CIDR:-192.168.50.1/24}"
AP_IP="${AP_CIDR%/*}"
WAN_IFACE="${WAN_IFACE:-eth0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOSTAPD_CONF_SRC="$REPO_ROOT/config/hostapd.conf"
FIREWALL_SCRIPT_SRC="$REPO_ROOT/scripts/apply-firewall.sh"
SYSTEMD_UNIT_SRC="$REPO_ROOT/systemd/gluetun-ap-firewall.service"
ROUTING_SCRIPT_SRC="$REPO_ROOT/scripts/apply-routing.sh"
ROUTING_UNIT_SRC="$REPO_ROOT/systemd/gluetun-ap-routing.service"

HOSTAPD_CONF_DST="/etc/hostapd/hostapd.conf"
SYSCTL_DROPIN="/etc/sysctl.d/99-gluetun-ap.conf"
FIREWALL_SCRIPT_DST="/usr/local/lib/gluetun-ap/apply-firewall.sh"
SYSTEMD_UNIT_DST="/etc/systemd/system/gluetun-ap-firewall.service"
ROUTING_SCRIPT_DST="/usr/local/lib/gluetun-ap/apply-routing.sh"
ROUTING_UNIT_DST="/etc/systemd/system/gluetun-ap-routing.service"
READY_UNIT_DST="/etc/systemd/system/gluetun-ap-ready.service"
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
DOCKER_LIST="/etc/apt/sources.list.d/docker.sources"
NETWORKD_DIR="/etc/systemd/network"
NETWORKD_CONF="/etc/systemd/network/10-${AP_IFACE}.network"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

backup_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cp -a "$path" "${path}.bak.$(date +%s)"
  fi
}

echo_step() {
  echo
  echo "==> $*"
}

require_root

ensure_packages() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo_step "Installing packages: ${missing[*]}"
    apt-get update
    apt-get install -y "${missing[@]}"
  else
    echo_step "Packages already present: $*"
  fi
}

ensure_packages hostapd

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    echo_step "Docker already installed"
    return
  fi
  echo_step "Installing Docker from official repository"
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$DOCKER_KEYRING"
  chmod a+r "$DOCKER_KEYRING"
  cat > "$DOCKER_LIST" <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: $DOCKER_KEYRING
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker.service
  systemctl enable --now containerd.service
  # Add invoking user to docker group if available
  if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || true
  fi
}

install_docker

stop_existing() {
  echo_step "Stopping existing AP services and Docker stack (if running)"
  systemctl stop gluetun-ap-ready.service gluetun-ap-routing.service gluetun-ap-firewall.service hostapd 2>/dev/null || true
  if command -v docker >/dev/null 2>&1; then
    (cd "$REPO_ROOT" && docker compose down || true)
  fi
}

stop_existing

ensure_networkd_static_ip() {
  echo_step "Configuring persistent static IP for ${AP_IFACE} via systemd-networkd"
  install -d "$NETWORKD_DIR"
  cat > "$NETWORKD_CONF" <<EOF
[Match]
Name=${AP_IFACE}

[Network]
Address=${AP_CIDR}
ConfigureWithoutCarrier=yes
DHCP=no
EOF
  # Prefer networkd; disable dhcpcd if present to avoid conflicts
  if systemctl list-unit-files | grep -q '^dhcpcd.service'; then
    systemctl disable --now dhcpcd || true
  fi
  systemctl enable --now systemd-networkd
}

echo_step "Copying hostapd config"
backup_if_exists "$HOSTAPD_CONF_DST"
install -d "$(dirname "$HOSTAPD_CONF_DST")"
install -m 644 "$HOSTAPD_CONF_SRC" "$HOSTAPD_CONF_DST"
if [[ -f /etc/default/hostapd ]]; then
  sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="'"$HOSTAPD_CONF_DST"'"|' /etc/default/hostapd
fi

echo_step "Setting static IP $AP_CIDR on $AP_IFACE (runtime)"
# Unblock Wi-Fi if rfkill is set
if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wifi || true
fi
ip link set "$AP_IFACE" up
ip addr replace "$AP_CIDR" dev "$AP_IFACE"

ensure_networkd_static_ip

echo_step "Unmasking/enabling hostapd"
systemctl unmask hostapd || true

echo_step "Enabling IPv4 forwarding"
cat > "$SYSCTL_DROPIN" <<EOF
net.ipv4.ip_forward=1
EOF
sysctl -p "$SYSCTL_DROPIN"

echo_step "Installing firewall script and unit"
install -d "$(dirname "$FIREWALL_SCRIPT_DST")"
install -m 755 "$FIREWALL_SCRIPT_SRC" "$FIREWALL_SCRIPT_DST"
install -m 644 "$SYSTEMD_UNIT_SRC" "$SYSTEMD_UNIT_DST"
systemctl daemon-reload
systemctl enable --now gluetun-ap-firewall.service

echo_step "Installing routing script and unit"
install -m 755 "$ROUTING_SCRIPT_SRC" "$ROUTING_SCRIPT_DST"
install -m 644 "$ROUTING_UNIT_SRC" "$ROUTING_UNIT_DST"
systemctl daemon-reload
# Enable routing unit so rules persist across reboot (runs after Docker)
systemctl enable gluetun-ap-routing.service

echo_step "Installing ready unit to start hostapd + dnsmasq after gluetun is healthy"
cat > "$READY_UNIT_DST" <<EOF
[Unit]
Description=Start AP (hostapd) and dnsmasq only after gluetun is healthy and routing applied
After=docker.service gluetun-ap-routing.service
Requires=docker.service gluetun-ap-routing.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '\
  for i in \$(seq 1 60); do \
    status=\$(docker inspect -f "{{.State.Health.Status}}" gluetun 2>/dev/null || true); \
    if [ "\$status" = "healthy" ]; then break; fi; \
    sleep 3; \
  done; \
  systemctl start hostapd; \
  cd "$REPO_ROOT" && docker compose up -d dnsmasq \
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl disable hostapd || true
systemctl enable gluetun-ap-ready.service

echo_step "Bringing up Docker stack (all services in compose)"
cd "$REPO_ROOT"
docker compose up -d

echo_step "Configuring routing and forwarding to gluetun"
# Grab gluetun IP on br-gluetun
GLUETUN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun 2>/dev/null || true)"
if [[ -z "$GLUETUN_IP" ]]; then
  echo "Could not determine gluetun IP; is the container running?" >&2
  exit 1
fi
# Policy route: AP subnet uses table 100 via gluetun bridge
ip rule del from 192.168.50.0/24 table 100 2>/dev/null || true
ip rule add from 192.168.50.0/24 table 100 pref 10000
ip route replace 192.168.50.0/24 dev "$AP_IFACE" table 100
ip route replace default via "$GLUETUN_IP" dev br-gluetun table 100
# Ensure no host MASQ to br-gluetun; let gluetun handle NAT to VPN
iptables -t nat -D POSTROUTING -s 192.168.50.0/24 -o br-gluetun -j MASQUERADE 2>/dev/null || true
# Insert high-priority forwards before Docker chains
iptables -I FORWARD 1 -i "$AP_IFACE" -o br-gluetun -s 192.168.50.0/24 -j ACCEPT
iptables -I FORWARD 2 -i br-gluetun -o "$AP_IFACE" -d 192.168.50.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo_step "Status"
ip -4 addr show dev "$AP_IFACE"
systemctl --no-pager status hostapd || true
systemctl --no-pager status gluetun-ap-firewall || true
docker compose ps

echo_step "Starting AP after gluetun is up"
if systemctl start gluetun-ap-ready.service; then
  echo "AP start triggered via ready unit."
else
  echo "Could not start ready unit now; it will run on next boot."
fi

echo
echo "Setup complete. Connect an AP client, it should get 192.168.50.x and exit via VPN."
