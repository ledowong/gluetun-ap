#!/bin/sh
set -e

# Ensure NAT from container bridge to VPN tunnel
iptables -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE

# Allow forward eth0 <-> tun0 (container bridge to VPN) for all (gluetun firewall still applies)
iptables -C FORWARD -i eth0 -o tun0 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i eth0 -o tun0 -j ACCEPT
iptables -C FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i tun0 -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT

exec /gluetun-entrypoint
