#!/usr/bin/env bash
# Mirror Forgejo repos updated in the last 48h to GitHub (Forgejo canonical,
# GitHub downstream). Opposite of coilysiren-forgejo-mirror.sh. Token via SSM.

set -uo pipefail

SINCE="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
API="https://forgejo.coilysiren.me/api/v1"

TOKEN="$(aws ssm get-parameter --name /forgejo/api-token --with-decryption \
  --query Parameter.Value --output text 2>/dev/null)"
if [[ "${#TOKEN}" -ne 40 ]]; then
  echo "ABORT: /forgejo/api-token fetch failed (got ${#TOKEN} chars)" >&2
  exit 1
fi

# Forgejo repos touched in the window. Search API sorted by update time, paged;
# stop once a page falls entirely outside the window (results are time-desc).
repos=""
page=1
while :; do
  resp="$(curl -s -H "Authorization: token $TOKEN" \
    "$API/repos/search?sort=updated&order=desc&limit=50&page=$page")"
  fresh="$(echo "$resp" | jq -r --arg since "$SINCE" \
    '.data[] | select(.archived | not) | select(.updated_at > $since) | .full_name')"
  total="$(echo "$resp" | jq -r '.data | length')"
  if [[ -n "$fresh" ]]; then
    repos+="$fresh"$'\n'
  fi
  if [[ "$total" -lt 50 || ( -z "$fresh" && "$total" -gt 0 ) ]]; then
    break
  fi
  page=$((page+1))
done
repos="$(echo "$repos" | sed '/^$/d' | sort -u)"

if [[ -z "$repos" ]]; then
  echo "no forgejo repos updated since $SINCE"
  exit 0
fi

mirrored=0
failed=0

for full_name in $repos; do
  tmp="$(mktemp -d /tmp/github-mirror.XXXXXX)"
  cred="$tmp/.gitcred"
  printf 'https://coilysiren:%s@forgejo.coilysiren.me\n' "$TOKEN" > "$cred"
  chmod 600 "$cred"

  # Create the GitHub repo if it does not exist yet (private to match Forgejo).
  if ! gh repo view "$full_name" >/dev/null 2>&1; then
    gh repo create "$full_name" --private >/dev/null 2>&1 || true
  fi

  if git -c credential.helper="store --file=$cred" \
       clone --quiet --mirror "https://forgejo.coilysiren.me/$full_name.git" "$tmp/repo" \
     && git -C "$tmp/repo" push --quiet --mirror "git@github.com:$full_name.git"; then
    echo "[$full_name] ok"
    mirrored=$((mirrored+1))
  else
    echo "[$full_name] FAIL"
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
