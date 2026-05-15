#!/usr/bin/env bash
# install-fdr-remake.sh - build and install the fdr-remake binary
# plus its systemd unit and sudoers fragment on kai-server.
#
# fdr-remake is the C++ rewrite of factorio-discord-relay, used as a
# sidecar to factorio-server.service for Factorio<>Discord chat
# bridging. Upstream: https://codeberg.org/Jaskowicz/fdr-remake.
# Tracking issue: coilysiren/infrastructure#101. Script issue: #139.
#
# Idempotent: re-run to upgrade. Skips clone+build if the binary
# already exists; pass FORCE=1 to rebuild even when present. Pin the
# D++ version via DPP_VERSION; the default is the version the bridge
# was last known to build against, so a rebuild months later still
# produces a working binary.
#
# Does not enable or start fdr-remake.service. SSM creds must land
# first (see coilysiren/agentic-os-kai SSM.md /factorio/* section). The
# script prints the exact next commands to run.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-fdr-remake.sh
# (sudo is invoked per-step, no need to run the whole script as root.)

set -euo pipefail

INFRA_SRC="${INFRA_SRC:-/home/kai/projects/coilysiren/infrastructure}"
FDR_DIR="${FDR_DIR:-/home/kai/.local/share/fdr-remake}"
FDR_BIN="${FDR_DIR}/fdr"
FDR_SRC="${FDR_SRC:-/home/kai/projects/fdr-remake}"
DPP_VERSION="${DPP_VERSION:-10.1.4}"
DPP_DEB="libdpp-${DPP_VERSION}-linux-x64.deb"
DPP_URL="https://github.com/brainboxdotcc/DPP/releases/download/v${DPP_VERSION}/${DPP_DEB}"
UNIT_DST="/etc/systemd/system/fdr-remake.service"
SUDOERS_DST="/etc/sudoers.d/kai-game-servers"
FORCE="${FORCE:-0}"

echo ">>> apt-installing build prereqs"
sudo apt-get update
sudo apt-get install -y cmake build-essential git pkg-config libssl-dev zlib1g-dev wget

echo ">>> checking D++ ${DPP_VERSION}"
# dpkg-query exits non-zero when the package is missing, which would
# trip set -e. Wrap in an if-else to make the missing-package branch
# explicit and survivable.
if dpkg-query -W -f='${Version}' libdpp 2>/dev/null | grep -q "^${DPP_VERSION}"; then
  echo "    libdpp ${DPP_VERSION} already installed"
else
  echo ">>> downloading + installing libdpp ${DPP_VERSION}"
  tmpdeb=$(mktemp --suffix=.deb)
  trap 'rm -f "${tmpdeb}"' EXIT
  wget -qO "${tmpdeb}" "${DPP_URL}"
  sudo dpkg -i "${tmpdeb}"
fi

if [ -x "${FDR_BIN}" ] && [ "${FORCE}" != "1" ]; then
  echo ">>> ${FDR_BIN} already exists, skipping clone+build (FORCE=1 to rebuild)"
else
  echo ">>> cloning + building fdr-remake into ${FDR_SRC}"
  if [ ! -d "${FDR_SRC}/.git" ]; then
    git clone https://codeberg.org/Jaskowicz/fdr-remake "${FDR_SRC}"
  else
    git -C "${FDR_SRC}" fetch --tags origin
    git -C "${FDR_SRC}" pull --ff-only
  fi
  cmake -S "${FDR_SRC}" -B "${FDR_SRC}/build"
  cmake --build "${FDR_SRC}/build" --parallel

  echo ">>> installing fdr binary -> ${FDR_BIN}"
  mkdir -p "${FDR_DIR}"
  install -m 0755 "${FDR_SRC}/build/fdr" "${FDR_BIN}"
fi

echo ">>> installing systemd unit -> ${UNIT_DST}"
sudo install -m 0644 "${INFRA_SRC}/systemd/fdr-remake.service" "${UNIT_DST}"

echo ">>> installing sudoers fragment -> ${SUDOERS_DST}"
sudo install -m 0440 -o root -g root "${INFRA_SRC}/sudoers/kai-game-servers" "${SUDOERS_DST}"
sudo visudo -cf "${SUDOERS_DST}"

echo ">>> reloading systemd"
sudo systemctl daemon-reload

cat <<'NEXT'

>>> install complete. fdr-remake.service is NOT enabled/started yet.

next:

1. stash SSM creds (once per cluster; SecureString unless noted):
     coily aws ssm put-parameter --type SecureString \
       --name /factorio/rcon-password --value FILL_ME_IN
     coily aws ssm put-parameter --type SecureString \
       --name /factorio/fdr/discord-bot-token --value FILL_ME_IN
     coily aws ssm put-parameter --type String \
       --name /factorio/fdr/channel-id --value FILL_ME_IN

2. restart factorio-server so it picks up the new --rcon-port /
   --console-log flags from scripts/factorio-server-start.sh:
     coily gaming factorio restart

3. enable + start the relay (factorio-server must be running first,
   the pre-script waits up to 60s for its console log):
     sudo systemctl enable --now fdr-remake.service

4. smoke test:
     sudo systemctl --no-pager --full status fdr-remake.service
     in-game /shout test -> should show in Discord
     Discord message in the configured channel -> should show in chat
NEXT
