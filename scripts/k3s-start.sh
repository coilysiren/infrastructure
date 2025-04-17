#!/bin/bash

TAILSCALE_IP=$(/usr/bin/tailscale ip -4 | head -n1)

/usr/local/bin/k3s server \
  --tls-san "$TAILSCALE_IP" \
  --bind-address "$TAILSCALE_IP" \
  --advertise-address "$TAILSCALE_IP"
