#!/usr/bin/env bash
# Provision the Forgejo token the tap-writer runner uses to push formula
# bumps into the coilyco-flight-deck homebrew tap(s).
#
# What it does:
#   1. Mints a Forgejo personal access token (scope: write:repository),
#      named "tap-bump", for the owning user via the Forgejo API.
#   2. Stores it at SSM /forgejo/tap-bump-token as a SecureString, without
#      ever echoing the value.
#
# The token is repository-write scoped (not admin). Because the owning user
# can write every coilyco-flight-deck repo, this single token covers all of
# the planned taps - the tap-writer runner reads it through a git credential
# helper (deploy/forgejo-runner-tap-writer.yml), so it never lands in a job
# environment or a Forgejo Actions secret.
#
# Run on a machine that has: Forgejo basic-auth credentials, AWS creds for
# SSM in us-east-1, and coily on PATH.
#
# Usage:
#   FORGEJO_USER=<user> FORGEJO_PASS=<pass> \
#     ./scripts/provision-tap-bump-token.sh
# Omit either var and the script prompts for it (password read silently).
#
# Idempotency: the SSM put runs WITHOUT --overwrite, so a re-run fails fast
# with ParameterAlreadyExists rather than clobbering a live token. To
# rotate, delete the old token in Forgejo + the SSM param first, then re-run.
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

# --- store in SSM ----------------------------------------------------------
# Pipe straight into coily; never print the token. No --overwrite so a stale
# value is never silently clobbered (infra Safety convention).
echo "Storing at SSM ${SSM_PATH} (SecureString, no overwrite)..."
coily ops aws ssm put-parameter \
  --name "${SSM_PATH}" \
  --type SecureString \
  --value "${token}" \
  --region "${AWS_REGION}"

unset token FORGEJO_PASS
echo "Done. Next: apply the runner, then it picks up the token from SSM:"
echo "  sudo k3s kubectl apply -f deploy/forgejo-runner-tap-writer.yml"
