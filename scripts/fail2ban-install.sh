#!/usr/bin/env bash
# Install and enable fail2ban with the sshd jail on kai-server (idempotent), to
# ban brute-force source IPs after repeated failed auth. See docs/fail2ban.md.

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
