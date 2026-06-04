#!/usr/bin/env bash
# Poll a tailnet host's SSH every POLL_INTERVAL seconds. Log state transitions.
# On dead->alive recovery, stream scripts/host-diag.sh into the remote and
# capture the output locally so each recurrence has a fresh post-recovery
# snapshot.
#
# Usage:
#   bash scripts/host-watch.sh <ssh-alias>
#   make host-watch host=<ssh-alias>
#   coily exec host-watch host=<ssh-alias>
#
# Tunables (env vars):
#   POLL_INTERVAL  seconds between probes (default 15)
#   OUT_DIR        where to write state log + recovery snapshots
#                  (default /tmp/host-watch-<alias>)
set -u

HOST="${1:?usage: host-watch.sh <ssh-alias>}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
OUT_DIR="${OUT_DIR:-/tmp/host-watch-${HOST}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG="${SCRIPT_DIR}/host-diag.sh"

mkdir -p "$OUT_DIR"
LOG="${OUT_DIR}/watch.log"

# coily is the boundary; the script never invokes ssh directly. coily's ops
# verbs are host-wide and don't bind to a repo, so it runs the same from any
# cwd (the canonical case is this repo).
COILY=(coily)

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"
}

probe() {
  "${COILY[@]}" ssh "$HOST" -- echo alive >/dev/null 2>&1
}

state="unknown"
log "watch started host=${HOST} poll=${POLL_INTERVAL}s out=${OUT_DIR}"

while true; do
  if probe; then
    new=alive
  else
    new=dead
  fi
  if [ "$new" != "$state" ]; then
    log "TRANSITION ${state} -> ${new}"
    if [ "$state" = "dead" ] && [ "$new" = "alive" ]; then
      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      out="${OUT_DIR}/recovery-${ts}.txt"
      log "firing diag, output: ${out}"
      "${COILY[@]}" ssh "$HOST" -- bash -s < "$DIAG" > "$out" 2>&1
      log "diag complete: $(wc -l < "$out") lines"
    fi
    state="$new"
  fi
  sleep "$POLL_INTERVAL"
done
