# Gluetun-backed Wi-Fi AP (Raspberry Pi)

This repo wires a Raspberry Pi AP so that only Wi-Fi clients use the gluetun VPN container, while host traffic stays on the normal WAN. The firewall is fail-closed: if VPN/tun stops passing traffic, AP clients simply lose internet instead of leaking to WAN.

**Tested/known-good**: Raspberry Pi 3B+, Raspberry Pi OS *Bullseye* 64-bit Lite. Newer kernels (Bookworm/Trixie) have shown Wi‑Fi driver instability/oops; use Bullseye for best stability.

## What’s here
- `docker-compose.yml`: gluetun container on a fixed bridge (`br-gluetun`).
- `.env.example`: NordVPN/gluetun env vars with DNS disabled.
- `config/hostapd.conf`: sample 5 GHz AP config for `wlan0`.
- `config/dnsmasq.conf`: DHCP/DNS for `192.168.50.0/24` handing out NordVPN DNS IPs.
- `scripts/apply-firewall.sh`: iptables rules to allow only AP → gluetun and drop AP → WAN (fail-closed).
- `systemd/gluetun-ap-firewall.service`: systemd unit to run the firewall script after Docker (enabled by the setup script).
- `docker/gluetun/init.sh`: ensures NAT/forwarding inside the gluetun container before starting.
- `scripts/apply-routing.sh` & `systemd/gluetun-ap-routing.service`: policy routing and FORWARD rules for AP → gluetun, enabled to persist across reboot (service waits/retries until gluetun is up).

## Addresses & interfaces
- AP subnet: `192.168.50.0/24`; Pi on `192.168.50.1`.
- AP interface: `wlan0`.
- WAN: `eth0`.
- Gluetun bridge: `br-gluetun` (created by Compose).

## Quick setup (preferred)
1) Copy `.env.example` to `.env` and fill your NordVPN credentials (OpenVPN or WireGuard key), keep `DNS_SERVER=off`, `FIREWALL=on`.
2) Run `sudo ./scripts/setup.sh` from the repo root on a **Bullseye 64-bit Lite** Pi 3B+. The script installs Docker/hostapd, configures static IP via systemd-networkd, brings up gluetun + dnsmasq, applies routing, and enables the firewall, ready, and routing units for reboot.
   - For WireGuard keys from NordVPN, use: `curl https://api.nordvpn.com/v1/users/services/credentials -u 'token:<nord_vpn_token>'`

## Firewall behavior
- `FORWARD` default DROP stays; a custom `AP_VPN` chain allows only `wlan0` → `br-gluetun` (with return traffic).  
- `DOCKER-USER` drop rule blocks `wlan0` → `eth0` so AP clients cannot leak to WAN.  
- NAT happens only inside gluetun (tun0); host does not MASQUERADE the AP subnet.  
- Host outbound and SSH inbound are unaffected (OUTPUT/INPUT chains).  
- Inside gluetun, `docker/gluetun/init.sh` adds MASQUERADE on `tun0` and permits forward `eth0 <-> tun0` so AP traffic can exit the VPN.  
- On the host, `gluetun-ap-routing.service` reapplies the AP policy route via `br-gluetun` and inserts high-priority FORWARD accepts for `wlan0 <-> br-gluetun` after boot.  

## Gluetun DNS choice
DNS inside gluetun is disabled (`DNS_SERVER=off`, `DOT=off`, `DNS=off`); `dnsmasq` hands out your VPN provider’s DNS IPs (`103.86.96.100`, `103.86.99.100`) so AP client DNS rides the VPN path and avoids DNS leaks.
