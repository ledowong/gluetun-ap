#!/usr/bin/env bash
# Apply routing and iptables for AP -> gluetun at boot.
set -euo pipefail

AP_IFACE="${AP_IFACE:-wlan0}"
AP_NET="${AP_NET:-192.168.50.0/24}"
GLUETUN_BR="${GLUETUN_BR:-br-gluetun}"
TABLE="${ROUTE_TABLE:-100}"
PRIORITY="${ROUTE_PRIORITY:-10000}"

ipt() {
  iptables -w "$@"
}

echo "Resolving gluetun container IP on ${GLUETUN_BR}..."
# Wait for gluetun to be up so systemd can retry if missing
for i in $(seq 1 20); do
  GLUETUN_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' gluetun 2>/dev/null || true)"
  if [[ -n "$GLUETUN_IP" ]]; then
    break
  fi
  sleep 3
done
if [[ -z "$GLUETUN_IP" ]]; then
  echo "gluetun IP not found after waiting; will retry via systemd restart." >&2
  exit 1
fi

echo "Configuring policy routing table ${TABLE} for ${AP_NET} via ${GLUETUN_BR} (${GLUETUN_IP})"
ip rule del from "${AP_NET}" table "${TABLE}" 2>/dev/null || true
ip rule add from "${AP_NET}" table "${TABLE}" pref "${PRIORITY}"
ip route replace "${AP_NET}" dev "${AP_IFACE}" table "${TABLE}"
ip route replace default via "${GLUETUN_IP}" dev "${GLUETUN_BR}" table "${TABLE}"

echo "Ensuring host does not MASQ AP subnet to ${GLUETUN_BR}"
ipt -t nat -D POSTROUTING -s "${AP_NET}" -o "${GLUETUN_BR}" -j MASQUERADE 2>/dev/null || true

echo "Normalizing FORWARD accepts for AP <-> gluetun (remove dups, insert once at top)"
while ipt -D FORWARD -i "${AP_IFACE}" -o "${GLUETUN_BR}" -s "${AP_NET}" -j ACCEPT 2>/dev/null; do :; done
while ipt -D FORWARD -i "${GLUETUN_BR}" -o "${AP_IFACE}" -d "${AP_NET}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do :; done
ipt -I FORWARD 1 -i "${AP_IFACE}" -o "${GLUETUN_BR}" -s "${AP_NET}" -j ACCEPT
ipt -I FORWARD 2 -i "${GLUETUN_BR}" -o "${AP_IFACE}" -d "${AP_NET}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo "Routing rules applied."
