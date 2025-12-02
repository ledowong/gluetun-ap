#!/usr/bin/env bash
set -euo pipefail

# Variables (override via environment)
AP_IFACE="${AP_IFACE:-wlan0}"
WAN_IFACE="${WAN_IFACE:-eth0}"
GLUETUN_BR="${GLUETUN_BR:-br-gluetun}"
AP_NET="${AP_NET:-192.168.50.0/24}"

ipt() {
  iptables -w "$@"
}

# Ensure custom chain exists and is clean
if ! ipt -t filter -nL AP_VPN >/dev/null 2>&1; then
  ipt -t filter -N AP_VPN
else
  ipt -t filter -F AP_VPN
fi

# Block AP -> WAN leaks early via DOCKER-USER (runs before Docker's rules)
if ! ipt -t filter -C DOCKER-USER -i "$AP_IFACE" -o "$WAN_IFACE" -s "$AP_NET" -j DROP 2>/dev/null; then
  ipt -t filter -I DOCKER-USER 1 -i "$AP_IFACE" -o "$WAN_IFACE" -s "$AP_NET" -j DROP
fi

# Allow AP -> gluetun bridge and return traffic
ipt -t filter -A AP_VPN -i "$AP_IFACE" -o "$GLUETUN_BR" -s "$AP_NET" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
ipt -t filter -A AP_VPN -i "$GLUETUN_BR" -o "$AP_IFACE" -d "$AP_NET" -m state --state ESTABLISHED,RELATED -j ACCEPT

# Hook AP_VPN into FORWARD early
if ! ipt -t filter -C FORWARD -j AP_VPN 2>/dev/null; then
  ipt -t filter -I FORWARD 1 -j AP_VPN
fi

# MASQUERADE AP subnet out to gluetun bridge only
if ! ipt -t nat -C POSTROUTING -s "$AP_NET" -o "$GLUETUN_BR" -j MASQUERADE 2>/dev/null; then
  ipt -t nat -A POSTROUTING -s "$AP_NET" -o "$GLUETUN_BR" -j MASQUERADE
fi

echo "Firewall rules applied for AP ${AP_NET} via ${GLUETUN_BR}; WAN ${WAN_IFACE} blocked for AP clients."
