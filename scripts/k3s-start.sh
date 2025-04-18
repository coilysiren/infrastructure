#!/bin/bash

cleanup() {
  pkill -9 containerd-shim
  pkill -9 containerd
  pkill -9 k3s
  exit 0
}

trap cleanup SIGTERM SIGINT

TAILSCALE_IP=$(/usr/bin/tailscale ip -4 | head -n1)

/usr/local/bin/k3s server \
  --tls-san "$TAILSCALE_IP" \
  --bind-address "$TAILSCALE_IP" \
  --advertise-address "$TAILSCALE_IP"
