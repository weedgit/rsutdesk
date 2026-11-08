#!/bin/sh
# RustDesk Team installer for Ubuntu/Debian: installs the .deb (with its dependencies), then the
# allowed IP list. Run it from this folder: ./install.sh
set -e
cd "$(dirname "$0")"
ips=$(sed 's/#.*//' allowed-ips.txt | tr ', \t' '\n\n\n' | grep -v '^$' | paste -sd, -)
[ -n "$ips" ] || { echo "allowed-ips.txt lists no IP address."; exit 1; }
deb=$(ls ./rustdesk*.deb | head -n 1)
[ -n "$deb" ] || { echo "No rustdesk .deb in this folder."; exit 1; }

# The unattended package and the standard one install the same files: replace one with the other.
for other in rustdesk rustdesk-unattended-wayland; do
    case "$deb" in *"/$other-"[0-9]*) continue ;; esac
    if dpkg -s "$other" 2>/dev/null | grep -q '^Status: install ok'; then sudo dpkg -r "$other"; fi
done
# --reinstall: team builds keep the same version number, and apt skips an "already installed" one.
sudo apt-get install -y --reinstall "$deb"

i=0
until systemctl is-active -q rustdesk || [ $i -ge 30 ]; do sleep 1; i=$((i + 1)); done
sleep 3   # let the service open its settings channel
echo "Allowing: $ips"
sudo rustdesk --option whitelist "$ips"
got=$(sudo rustdesk --option whitelist | tr -d '\r\n')
[ "$got" = "$ips" ] || { echo "The allowed IP list did not stick (it reads '$got')."; exit 1; }
echo "Done. RustDesk runs as a service and starts at boot. Allowed: $got"
