#!/usr/bin/env bash
# coilysiren-forgejo-mirror.sh - mirror every coilysiren GitHub repo pushed
# in the last 48h to the self-hosted Forgejo at forgejo.coilysiren.me.
#
# Invoked by coilysiren-forgejo-mirror.timer daily ~03:45, and on-demand via
# `coily systemctl start coilysiren-forgejo-mirror.service` or by running
# this script directly.
#
# Why: the Mac multi-push only mirrors repos Kai pushes from her Mac. Code
# that reaches GitHub from any other machine or the web never lands on
# Forgejo. This sweep closes that gap. The 48h window (not 24h) gives one
# full day of overlap, so a single failed run self-heals the next night.
#
# Per repo: clone --mirror from GitHub, push --mirror to Forgejo, delete.
# One at a time. A failure on one repo does not abort the sweep.
#
# Auth: GitHub clone uses kai-server's existing git SSH key. Forgejo is
# HTTPS-only (SSH disabled), so push + create-if-missing use the Forgejo
# API token from SSM /forgejo/api-token, fetched once at startup. The
# token reaches git via a mode-600 credential file inside the per-repo
# temp dir, never argv - so it stays out of `ps`. See infrastructure#260.

set -uo pipefail

SINCE="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
API="https://forgejo.coilysiren.me/api/v1"

TOKEN="$(aws ssm get-parameter --name /forgejo/api-token --with-decryption \
  --query Parameter.Value --output text 2>/dev/null)"
if [[ "${#TOKEN}" -ne 40 ]]; then
  echo "ABORT: /forgejo/api-token fetch failed (got ${#TOKEN} chars)" >&2
  exit 1
fi

# coilysiren repos with a push in the window. GitHub REST, sorted by push
# time - plain pagination, no GraphQL, no rate-limit pressure.
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
  tmp="$(mktemp -d /tmp/forgejo-mirror.XXXXXX)"
  cred="$tmp/.gitcred"
  printf 'https://coilysiren:%s@forgejo.coilysiren.me\n' "$TOKEN" > "$cred"
  chmod 600 "$cred"

  # Create the Forgejo repo if it does not exist yet; 409 if it does.
  curl -s -o /dev/null -X POST \
    -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"private\":true,\"default_branch\":\"main\"}" \
    "$API/user/repos"

  if git clone --quiet --mirror "git@github.com:coilysiren/$name.git" "$tmp/repo" \
     && git -C "$tmp/repo" -c credential.helper="store --file=$cred" \
          push --quiet --mirror "https://forgejo.coilysiren.me/coilysiren/$name.git"; then
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
