#!/usr/bin/env bash
# Join the host this runs on to kai-server's k3s cluster as a worker (agent).
# Run ON the joining node. Design + rationale: infrastructure#258.
set -euo pipefail

SERVER_HOST="${1:-kai-server}"
SERVER_USER="${SERVER_USER:-kai}"

# Pin the agent to the server's running k3s version (re-check `k3s --version`).
K3S_VERSION="${K3S_VERSION:-v1.32.3+k3s1}"

command -v tailscale >/dev/null || { echo "tailscale not found on PATH" >&2; exit 1; }

# kai-server runs k3s flanneled over tailscale0; ser8 has no IPv4 LAN lease, so
# the tailscale0 plane is the only IPv4 path. The agent must match both.
SERVER_IP="$(tailscale ip -4 "$SERVER_HOST" | head -1)"
NODE_IP="$(tailscale ip -4 | head -1)"
[ -n "$SERVER_IP" ] || { echo "could not resolve tailnet IPv4 for $SERVER_HOST" >&2; exit 1; }
[ -n "$NODE_IP" ]   || { echo "could not resolve this host's tailnet IPv4" >&2; exit 1; }

echo "Joining $(hostname) ($NODE_IP) to k3s server $SERVER_HOST ($SERVER_IP:6443) as a worker..."
echo "Fetching node-token from $SERVER_USER@$SERVER_HOST (sudo password prompt follows)..."

# -tt forces a tty so sudo can prompt (a remote command otherwise gets none);
# the prompt goes to stderr, so stdout is just the token line (starts with K10).
TOKEN="$(ssh -tt "${SERVER_USER}@${SERVER_HOST}" 'sudo cat /var/lib/rancher/k3s/server/node-token' | tr -d '\r' | grep -m1 '^K')" || true
[ -n "$TOKEN" ] || { echo "empty node-token; aborting (sudo failed or wrong path)" >&2; exit 1; }

curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION="$K3S_VERSION" \
    K3S_URL="https://${SERVER_IP}:6443" \
    K3S_TOKEN="$TOKEN" \
    sh -s - --node-ip "$NODE_IP" --flannel-iface tailscale0

echo
echo "Done. Verify: sudo k3s kubectl get nodes -o wide (on the server)"
echo "Uninstall later: /usr/local/bin/k3s-agent-uninstall.sh"
