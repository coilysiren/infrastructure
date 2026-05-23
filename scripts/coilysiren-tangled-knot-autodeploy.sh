#!/usr/bin/env bash
# coilysiren-tangled-knot-autodeploy.sh - autodeploy the Tangled knot
# (tangled.coilysiren.me) on kai-server. Picks up new release tags from
# tangled.org/tangled.org/core and rolls them out behind a safety
# sandwich: backup, verify, build, atomic symlink swap, restart,
# healthcheck, auto-rollback on failure.
#
# Invoked by coilysiren-tangled-knot-autodeploy.timer daily ~04:00, and
# on-demand via
# `coily systemctl start coilysiren-tangled-knot-autodeploy.service`
# or by running this script directly as root.
#
# Why: the knot is currently pinned to whatever tag install-tangled-knot.sh
# baked in. Upstream ships new alpha tags roughly weekly. This timer keeps
# the live deploy current without manual intervention, and refuses to leave
# the box in a broken state when an upgrade misbehaves.
#
# The previous Nix store path is retained automatically (no GC root games
# are needed here), so the rollback in step 9 is a symlink flip plus a
# service restart. See infrastructure#293.

set -uo pipefail

KNOT_DIR="/opt/tangled-knot"
KNOT_CURRENT="$KNOT_DIR/current"
KNOT_STATE="/var/lib/tangled-knot"
KNOT_BACKUP_DIR="/var/backups/tangled-knot"
KNOT_BACKUP_KEEP=5
KNOT_HEALTH_URL="https://tangled.coilysiren.me/"
KNOT_HEALTH_TIMEOUT=120
KNOT_HEALTH_INTERVAL=5
UPSTREAM="https://tangled.org/tangled.org/core"
SERVICE="tangled-knot.service"

# 1) Newest v*-alpha tag at the upstream knot repo. Plain ls-remote, no GraphQL.
echo ">>> resolving newest v*-alpha tag from $UPSTREAM"
NEW_TAG="$(git ls-remote --tags --refs "$UPSTREAM" 2>/dev/null \
  | awk '{print $2}' \
  | sed 's|^refs/tags/||' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-alpha$' \
  | sort -V \
  | tail -n1)"

if [[ -z "$NEW_TAG" ]]; then
  echo "ABORT: no v*-alpha tag found at $UPSTREAM" >&2
  exit 1
fi
echo "    newest: $NEW_TAG"

# 2) No-op when the symlink already names the new tag. Nix store paths
# embed the flake $name (which includes the tag) so a substring match is
# enough; the build is the costly step and we want to skip it cheaply.
if [[ ! -L "$KNOT_CURRENT" ]]; then
  echo "ABORT: $KNOT_CURRENT is not a symlink; first install via install-tangled-knot.sh" >&2
  exit 1
fi
CURRENT_STORE="$(readlink -f "$KNOT_CURRENT")"
if [[ -z "$CURRENT_STORE" ]]; then
  echo "ABORT: $KNOT_CURRENT does not resolve" >&2
  exit 1
fi
if [[ "$CURRENT_STORE" == *"$NEW_TAG"* ]]; then
  echo "$NEW_TAG already deployed ($CURRENT_STORE) - no-op"
  exit 0
fi
echo "    current: $CURRENT_STORE"

# 3) Snapshot /var/lib/tangled-knot/ as a tar.gz. Taken with the knot
# running; this is rollback insurance, not a transaction-consistent
# restore point. The real recovery path is the previous store symlink.
ts="$(date -u +%Y%m%dT%H%M%SZ)"
backup="$KNOT_BACKUP_DIR/tangled-knot-$ts.tar.gz"
echo ">>> backing up $KNOT_STATE -> $backup"
mkdir -p "$KNOT_BACKUP_DIR"
tar -czf "$backup" -C "$(dirname "$KNOT_STATE")" "$(basename "$KNOT_STATE")"

# 4) Verify the backup before letting the deploy proceed.
echo ">>> verifying backup"
if [[ ! -s "$backup" ]]; then
  echo "ABORT: backup empty at $backup" >&2
  exit 1
fi
if ! tar -tzf "$backup" >/dev/null 2>&1; then
  echo "ABORT: backup not readable as tar.gz at $backup" >&2
  exit 1
fi
# Sanity: knotserver.db should be in there; otherwise we backed up an
# empty state dir, which is no backup at all.
if ! tar -tzf "$backup" 2>/dev/null | grep -qE '(^|/)tangled-knot/knotserver\.db$'; then
  echo "ABORT: backup missing knotserver.db at $backup" >&2
  exit 1
fi
echo "    verified: $backup"

# 4b) Rotate. Keep the $KNOT_BACKUP_KEEP newest tar.gz files. #291 will
# replace this with size-based rotation; keep-last-N is the simplest
# shape that swaps cleanly when that lands.
echo ">>> rotating backups (keep last $KNOT_BACKUP_KEEP)"
find "$KNOT_BACKUP_DIR" -maxdepth 1 -type f -name 'tangled-knot-*.tar.gz' \
  -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr \
  | awk -v keep="$KNOT_BACKUP_KEEP" 'NR>keep {print $2}' \
  | xargs -r rm -f

# 5) Build the new tag via the audited coily nix wrapper.
flake="git+${UPSTREAM}?ref=refs/tags/${NEW_TAG}#knot"
echo ">>> building $flake"
if ! NEW_STORE="$(coily pkg nix build "$flake" --no-link --print-out-paths 2>&1)"; then
  echo "ABORT: coily pkg nix build failed:" >&2
  echo "$NEW_STORE" >&2
  exit 1
fi
NEW_STORE="$(printf '%s\n' "$NEW_STORE" | tail -n1)"
if [[ -z "$NEW_STORE" || ! -d "$NEW_STORE" ]]; then
  echo "ABORT: build did not produce a usable store path (got '$NEW_STORE')" >&2
  exit 1
fi
echo "    built: $NEW_STORE"

# 6) Atomic symlink swap. `ln -sfn` is not atomic with respect to a
# reader because it can briefly remove and recreate the link; `mv -Tf`
# of a freshly-built link rename-replaces the target in one inode-table
# update. See `man 2 rename`.
echo ">>> swapping $KNOT_CURRENT: $CURRENT_STORE -> $NEW_STORE"
ln -sfn "$NEW_STORE" "$KNOT_CURRENT.new"
mv -Tf "$KNOT_CURRENT.new" "$KNOT_CURRENT"

# 7) Restart the knot so it picks up the new binary.
echo ">>> restarting $SERVICE"
systemctl restart "$SERVICE"

# 8) Poll the public HTTPS endpoint until it returns 200 or we give up.
echo ">>> healthchecking $KNOT_HEALTH_URL (timeout ${KNOT_HEALTH_TIMEOUT}s)"
deadline=$(( $(date +%s) + KNOT_HEALTH_TIMEOUT ))
healthy=0
while (( $(date +%s) < deadline )); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$KNOT_HEALTH_URL" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    healthy=1
    break
  fi
  sleep "$KNOT_HEALTH_INTERVAL"
done

if (( healthy == 1 )); then
  echo "    healthy ($KNOT_HEALTH_URL returned 200)"
  echo
  echo "deployed=$NEW_TAG store=$NEW_STORE backup=$backup"
  exit 0
fi

# 9) Rollback. Symlink flip to the previous store path + restart. If the
# previous store path is itself unhealthy we leave the box for human
# triage; the backup path is on the last line of the report.
echo "FAIL: healthcheck did not return 200 within ${KNOT_HEALTH_TIMEOUT}s; rolling back to $CURRENT_STORE" >&2
ln -sfn "$CURRENT_STORE" "$KNOT_CURRENT.new"
mv -Tf "$KNOT_CURRENT.new" "$KNOT_CURRENT"
systemctl restart "$SERVICE"

rb_deadline=$(( $(date +%s) + 60 ))
rb_healthy=0
while (( $(date +%s) < rb_deadline )); do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$KNOT_HEALTH_URL" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" ]]; then
    rb_healthy=1
    break
  fi
  sleep "$KNOT_HEALTH_INTERVAL"
done

if (( rb_healthy == 1 )); then
  echo "rollback healthy at $CURRENT_STORE; the new tag $NEW_TAG failed" >&2
else
  echo "rollback ALSO failed healthcheck; backup at $backup; manual recovery needed" >&2
fi
exit 2
