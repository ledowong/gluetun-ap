# Gluetun-backed Wi-Fi AP (Raspberry Pi)

This repo wires a Raspberry Pi AP so that only Wi-Fi clients use the gluetun VPN container, while host traffic stays on the normal WAN. The firewall is fail-closed: if VPN/tun stops passing traffic, AP clients simply lose internet instead of leaking to WAN.

## What’s here
- `docker-compose.yml`: gluetun container on a fixed bridge (`br-gluetun`).
- `.env.example`: NordVPN/gluetun env vars with DNS disabled.
- `config/hostapd.conf`: sample 5 GHz AP config for `wlan0`.
- `config/dnsmasq.conf`: DHCP/DNS for `192.168.50.0/24` handing out NordVPN DNS IPs.
- `scripts/apply-firewall.sh`: iptables rules to allow only AP → gluetun and drop AP → WAN.
- `systemd/gluetun-ap-firewall.service`: systemd unit to run the firewall script after Docker (installed, not enabled by default).
- `docker/gluetun/init.sh`: ensures NAT/forwarding inside the gluetun container before starting.
- `scripts/apply-routing.sh` & `systemd/gluetun-ap-routing.service`: policy routing and FORWARD rules for AP → gluetun, enabled to persist across reboot.

## Addresses & interfaces
- AP subnet: `192.168.50.0/24`; Pi on `192.168.50.1`.
- AP interface: `wlan0`.
- WAN: `eth0`.
- Gluetun bridge: `br-gluetun` (created by Compose).

## Setup steps
1) Install dependencies (example): `sudo apt install hostapd dnsmasq iptables-persistent docker.io docker-compose-plugin`  
2) Set `wlan0` static IP `192.168.50.1/24` (e.g., `/etc/dhcpcd.conf`).  
3) hostapd: copy `config/hostapd.conf` to `/etc/hostapd/hostapd.conf`, edit SSID/passphrase, enable/start hostapd.  
4) dnsmasq: copy `config/dnsmasq.conf` to `/etc/dnsmasq.d/ap.conf`, adjust if needed, restart dnsmasq.  
5) IP forwarding: create `/etc/sysctl.d/99-ipforward.conf` with `net.ipv4.ip_forward=1`, then `sudo sysctl --system`.  
6) iptables backend: ensure iptables-legacy (better with Docker on Pi): `sudo update-alternatives --config iptables` → pick legacy.  
7) Firewall: place `scripts/apply-firewall.sh` at `/usr/local/lib/gluetun-ap/apply-firewall.sh`, `chmod +x` it. Copy `systemd/gluetun-ap-firewall.service` to `/etc/systemd/system/` and edit `ExecStart` path if different. Then `sudo systemctl daemon-reload && sudo systemctl enable --now gluetun-ap-firewall.service`.  
8) Gluetun env: copy `.env.example` to `.env`, fill NordVPN credentials and region.  
9) Bring up VPN: `docker compose up -d` (from repo directory). The `br-gluetun` bridge will be created automatically.  
10) Routing/NAT persistence: `scripts/setup.sh` installs `gluetun-ap-routing.service`, which re-applies the AP→gluetun policy route and FORWARD rules after Docker starts. It is enabled by default in the setup script.  

## Firewall behavior
- `FORWARD` default DROP stays; a custom `AP_VPN` chain allows only `wlan0` → `br-gluetun` (with return traffic).  
- `DOCKER-USER` drop rule blocks `wlan0` → `eth0` so AP clients cannot leak to WAN.  
- NAT only for `192.168.50.0/24` out `br-gluetun` (no MASQUERADE to WAN).  
- Host outbound and SSH inbound are unaffected (OUTPUT/INPUT chains).  
- Inside gluetun, `docker/gluetun/init.sh` adds MASQUERADE on `tun0` and permits forward `eth0 <-> tun0` so AP traffic can exit the VPN.  
- On the host, `gluetun-ap-routing.service` reapplies the AP policy route via `br-gluetun` and inserts high-priority FORWARD accepts for `wlan0 <-> br-gluetun` after boot.  

## Gluetun DNS choice
DNS inside gluetun is disabled (`DNS_SERVER=off`, `DOT=off`, `DNS=off`); `dnsmasq` hands out NordVPN DNS IPs (`103.86.96.100`, `103.86.99.100`) so AP client DNS rides the VPN path.

## Variables for `apply-firewall.sh`
- `AP_IFACE` (default `wlan0`), `WAN_IFACE` (default `eth0`), `GLUETUN_BR` (default `br-gluetun`), `AP_NET` (default `192.168.50.0/24`).  
These can be exported before running the script if your naming changes.
