#!/bin/bash

cleanup() {
  pkill -9 containerd-shim
  pkill -9 containerd
  pkill -9 k3s
  exit 0
}

trap cleanup SIGTERM SIGINT

# infra#163 - flannel on tailnet plane, node-ip resolved at runtime, never hardcoded
for _ in $(seq 1 30); do
  NODE_IP="$(tailscale ip -4 2>/dev/null | head -1)"
  [ -n "$NODE_IP" ] && break
  sleep 2
done

# exec so k3s is the unit's Main PID, else its sd_notify READY=1 is dropped
# (Type=notify) and the unit hangs in 'activating'. See docs/k3s-deploy-notes.md.
exec /usr/local/bin/k3s server \
  --write-kubeconfig-mode=0644 \
  --node-ip="$NODE_IP" \
  --flannel-iface=tailscale0 \
  --kubelet-arg=system-reserved=cpu=1000m,memory=1Gi \
  --kubelet-arg=kube-reserved=cpu=1000m,memory=1Gi
