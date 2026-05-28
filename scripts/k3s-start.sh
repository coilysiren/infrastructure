#!/bin/bash

cleanup() {
  pkill -9 containerd-shim
  pkill -9 containerd
  pkill -9 k3s
  exit 0
}

trap cleanup SIGTERM SIGINT

# infra#163 - flannel on tailnet plane, node-ip resolved at runtime, never hardcode the tailnet IP
for _ in $(seq 1 30); do
  NODE_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$NODE_IP" ] && break
  sleep 2
done

# exec so k3s becomes the unit's Main PID; otherwise its sd_notify READY=1 is
# dropped (Type=notify + default NotifyAccess=main) and the unit hangs in
# 'activating' forever. Teardown is handled by the unit's ExecStop lines.
exec /usr/local/bin/k3s server \
  --write-kubeconfig-mode=0644 \
  --node-ip="$NODE_IP" \
  --flannel-iface=tailscale0
