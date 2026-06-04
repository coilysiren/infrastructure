#!/usr/bin/env bash
# Mirror coilysiren GitHub repos pushed in the last 48h to the Tangled knot over
# loopback SSH. Repos must be pre-registered; failures don't abort (infrastructure#294).

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

# Pin git's SSH to the dedicated key (IdentitiesOnly blocks agent-key fallback;
# accept-new auto-trusts the loopback host key, low risk on the same box).
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
