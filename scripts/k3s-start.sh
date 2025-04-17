#!/bin/bash

TAILSCALE_IP=$(/usr/bin/tailscale ip -4 | head -n1)

/usr/local/bin/k3s server \
  --tls-san "$TAILSCALE_IP" \
  --bind-address "$TAILSCALE_IP" \
  --advertise-address "$TAILSCALE_IP"

# Activate this script with:
#
# sudo systemctl edit k3s
#
# [Service]
# ExecStart=
# ExecStart=bash -c /home/kai/projects/infrastructure/scripts/k3s-start.sh
#
# sudo systemctl daemon-reload
# sudo systemctl restart k3s
