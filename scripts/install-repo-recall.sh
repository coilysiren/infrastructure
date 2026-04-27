#!/usr/bin/env bash
# Build repo-recall on kai-server and install it as a systemd service.
# Idempotent: run again to upgrade.
#
# Run as: sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-repo-recall.sh
# (the build step needs to run as `kai`; the install step needs root.)

set -euo pipefail

REPO_RECALL_SRC="${REPO_RECALL_SRC:-/home/kai/projects/coilysiren/repo-recall}"
INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
BIN_DST="/usr/local/bin/repo-recall"
UNIT_DST="/etc/systemd/system/repo-recall.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "must run as root (sudo)" >&2
  exit 1
fi

if [[ ! -d "$REPO_RECALL_SRC" ]]; then
  echo "repo-recall source not found at $REPO_RECALL_SRC" >&2
  echo "run scripts/clone-coilysiren-repos.sh first" >&2
  exit 1
fi

echo ">>> building repo-recall as kai (release)"
# `sudo -u kai bash -c` is non-login non-interactive: it skips ~/.bashrc and
# ~/.profile, so a rustup-managed cargo at ~/.cargo/bin is invisible. Source
# ~/.cargo/env explicitly so we don't fall through to an older apt-managed
# cargo (which on kai-server is 1.75 and rejects edition2024 deps).
sudo -u kai bash -c "source ~kai/.cargo/env && cd '$REPO_RECALL_SRC' && cargo build --release"

echo ">>> installing binary -> $BIN_DST"
install -m 0755 "$REPO_RECALL_SRC/target/release/repo-recall" "$BIN_DST"

echo ">>> installing unit -> $UNIT_DST"
install -m 0644 "$INFRA_SRC/systemd/repo-recall.service" "$UNIT_DST"

echo ">>> reloading systemd"
systemctl daemon-reload

echo ">>> enabling + (re)starting repo-recall.service"
systemctl enable repo-recall.service
systemctl restart repo-recall.service

sleep 2
systemctl --no-pager --full status repo-recall.service || true

echo
echo "next: expose over tailscale (run as kai, once):"
echo "  tailscale serve --bg --https=443 http://127.0.0.1:7777"
echo "verify with:"
echo "  tailscale serve status"
echo "  curl -sf https://kai-server.<tailnet>.ts.net/api/scan-version"
