#!/usr/bin/env bash
# Mint a write:repository Forgejo token "tap-bump" and store it at SSM
# /forgejo/tap-bump-token (SecureString, never echoed) for the tap-writer runner.

# Set FORGEJO_USER/FORGEJO_PASS or be prompted. The SSM put omits --overwrite, so a
# re-run fails fast rather than clobbering. Rotate by deleting old token + param first.
set -euo pipefail

FORGEJO_BASE_URL="${FORGEJO_BASE_URL:-https://forgejo.coilysiren.me}"
SSM_PATH="${SSM_PATH:-/forgejo/tap-bump-token}"
TOKEN_NAME="${TOKEN_NAME:-tap-bump}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# --- credentials -----------------------------------------------------------
if [ -z "${FORGEJO_USER:-}" ]; then
  read -rp "Forgejo user: " FORGEJO_USER
fi
if [ -z "${FORGEJO_PASS:-}" ]; then
  read -rsp "Forgejo password/token for ${FORGEJO_USER}: " FORGEJO_PASS
  echo
fi

# --- mint the token --------------------------------------------------------
# Forgejo returns the token value in `.sha1`; it is shown exactly once.
echo "Minting Forgejo token '${TOKEN_NAME}' (scope write:repository) for ${FORGEJO_USER}..."
mint_resp=$(curl -fsS -u "${FORGEJO_USER}:${FORGEJO_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "${FORGEJO_BASE_URL}/api/v1/users/${FORGEJO_USER}/tokens" \
  -d "{\"name\":\"${TOKEN_NAME}\",\"scopes\":[\"write:repository\"]}")

token=$(printf '%s' "${mint_resp}" | python3 -c \
  'import sys,json; print(json.load(sys.stdin).get("sha1",""))')
if [ -z "${token}" ]; then
  echo "error: no token in mint response (name already exists? scope rejected?)" >&2
  printf '%s\n' "${mint_resp}" >&2
  exit 1
fi

# Store in SSM: pipe straight into coily, never print the token. No --overwrite, so a
# stale value is never silently clobbered (infra Safety convention).
echo "Storing at SSM ${SSM_PATH} (SecureString, no overwrite)..."
coily ops aws ssm put-parameter \
  --name "${SSM_PATH}" \
  --type SecureString \
  --value "${token}" \
  --region "${AWS_REGION}"

unset token FORGEJO_PASS
echo "Done. Next: apply the runner, then it picks up the token from SSM:"
echo "  sudo k3s kubectl apply -f deploy/forgejo-runner-tap-writer.yml"
