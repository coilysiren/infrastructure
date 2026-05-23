#!/usr/bin/env bash
# coilysiren-tangled-knot-mirror.sh - mirror every coilysiren GitHub repo
# pushed in the last 48h to the self-hosted Tangled knot at
# tangled.coilysiren.me.
#
# Invoked by coilysiren-tangled-knot-mirror.timer daily ~04:15, and on-
# demand via
# `coily systemctl start coilysiren-tangled-knot-mirror.service` or by
# running this script directly.
#
# Why: same gap the Forgejo mirror closes for Forgejo. Code that reaches
# GitHub from any host other than Kai's Mac (web edits, kai-server,
# dispatch sessions, CI, other workstations) never lands on the knot.
# This sweep closes that gap. The 48h window (not 24h) gives one full
# day of overlap, so a single failed run self-heals the next night.
#
# Per repo: clone --mirror from GitHub, push --mirror to the knot at
# git@localhost, delete. One at a time. A single-repo failure does not
# abort the sweep.
#
# Auth: the knot is SSH-only for git write (no HTTPS API path). Push
# via loopback SSH so we hit the same sshd that the knot's
# AuthorizedKeysCommand (/etc/ssh/tangled-knot-keyfetch) gates. The
# keyfetch wrapper resolves atproto-registered keys via the running
# knot, so the SSH keypair we use here must be registered against
# Kai's knot-owner DID through the appview at https://tangled.org. A
# dedicated ed25519 keypair lives at TANGLED_MIRROR_KEY (default
# /home/kai/.ssh/tangled-knot-mirror_ed25519); see the install script
# header for the generation + DID-registration steps. See
# infrastructure#294.
#
# URL shape: ssh://git@localhost/<KNOT_SERVER_OWNER>/<repo>. Two-
# component owner/repo form per upstream knot's SSH Guard - confirmed
# from tangled.org/core knotserver/internal.go. KNOT_SERVER_OWNER is
# Kai's DID, sourced from /etc/tangled-knot/knot.env so a single edit
# there flows to both the knot and this mirror.
#
# Create-if-missing: skipped (infrastructure#294 option 1). Repos must
# be pre-registered via the appview before the mirror can push to them.
# A push to an unregistered repo fails and the script logs FAIL and
# moves on. Follow-up to lift the manual step lives at
# infrastructure#294's "appview registration RPC" comment - file a
# separate issue when that work starts.

set -uo pipefail

SINCE="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
KNOT_ENV="${KNOT_ENV:-/etc/tangled-knot/knot.env}"
SSH_KEY="${TANGLED_MIRROR_KEY:-/home/kai/.ssh/tangled-knot-mirror_ed25519}"

if [[ ! -r "$KNOT_ENV" ]]; then
  echo "ABORT: cannot read $KNOT_ENV (knot not installed?)" >&2
  exit 1
fi

# Knot owner DID drives the push URL path. Sourcing one line (not the
# whole file) so an unrelated env addition cannot perturb this script.
KNOT_SERVER_OWNER="$(grep -E '^KNOT_SERVER_OWNER=' "$KNOT_ENV" | head -n1 | cut -d= -f2-)"
if [[ -z "$KNOT_SERVER_OWNER" ]]; then
  echo "ABORT: KNOT_SERVER_OWNER not set in $KNOT_ENV" >&2
  exit 1
fi

if [[ ! -r "$SSH_KEY" ]]; then
  echo "ABORT: SSH key $SSH_KEY missing or unreadable; see install-coilysiren-tangled-knot-mirror.sh header" >&2
  exit 1
fi

# Pin git's SSH to the dedicated key. IdentitiesOnly stops it falling
# back to other agent keys; accept-new auto-trusts the loopback host
# key on first run (low risk, sshd is on the same box).
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

# coilysiren repos with a push in the window. GitHub REST, sorted by
# push time - plain pagination, no GraphQL, no rate-limit pressure.
repos="$(gh api --paginate 'user/repos?affiliation=owner&sort=pushed&per_page=100' \
  --jq '.[] | select(.archived | not) | select(.pushed_at > "'"$SINCE"'") | .name' \
  2>/dev/null)"

if [[ -z "$repos" ]]; then
  echo "no coilysiren repos pushed since $SINCE"
  exit 0
fi

mirrored=0
failed=0

for name in $repos; do
  tmp="$(mktemp -d /tmp/tangled-knot-mirror.XXXXXX)"

  # ssh:// form (not scp-style) so the DID's embedded colons in the
  # path component don't confuse the URL parser.
  knot_url="ssh://git@localhost/${KNOT_SERVER_OWNER}/${name}"

  if git clone --quiet --mirror "git@github.com:coilysiren/$name.git" "$tmp/repo" \
     && git -C "$tmp/repo" push --quiet --mirror "$knot_url"; then
    echo "[$name] ok"
    mirrored=$((mirrored+1))
  else
    echo "[$name] FAIL"
    failed=$((failed+1))
  fi

  rm -rf "$tmp"
done

echo
echo "mirrored=$mirrored failed=$failed since=$SINCE"
# Non-zero only on a genuine failure, so `systemctl status` flags it.
if (( failed > 0 )); then
  exit 2
fi
