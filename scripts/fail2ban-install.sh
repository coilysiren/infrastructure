#!/usr/bin/env bash
# fail2ban-install.sh - install and enable fail2ban with the sshd jail on
# kai-server. Idempotent. Installs the package, drops the repo's explicit
# jail.local, enables + starts the service, and prints status.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/fail2ban-install.sh
#
# Why: sshd listens on 0.0.0.0:22 and takes continuous brute-force scans;
# nothing was throttling failed auth. This bans source IPs after N failed
# attempts. No sshd binding, firewall topology, or exposure change. See
# infrastructure#104 (parent audit: infrastructure#103).

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"

echo ">>> installing fail2ban"
if ! dpkg -s fail2ban >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y fail2ban
else
  echo "    already installed: $(fail2ban-client --version 2>/dev/null | head -1)"
fi

echo ">>> installing /etc/fail2ban/jail.local"
sudo install -m 0644 "$INFRA_SRC/fail2ban/jail.local" /etc/fail2ban/jail.local

echo ">>> enabling + (re)starting fail2ban"
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban

echo
echo ">>> fail2ban-client status"
sudo fail2ban-client status
echo
echo ">>> fail2ban-client status sshd"
sudo fail2ban-client status sshd
