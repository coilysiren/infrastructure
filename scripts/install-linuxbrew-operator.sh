#!/usr/bin/env bash
# install-linuxbrew-operator.sh - install or upgrade the linuxbrew-operator
# Helm chart on the kai-server k3s cluster via the helm-git plugin.
#
# By design: no container registry holds anything we produce. Helm clones the
# chart from this repo's sibling at coilysiren/linuxbrew-operator via SSH; the
# controller Pod's init container clones the same repo again at startup and
# builds the manager binary on the cluster.
#
# Idempotent: re-run to upgrade. Re-run with a different REF= to pin a tag.
#
# Run as: bash /home/kai/projects/coilysiren/infrastructure/scripts/install-linuxbrew-operator.sh
# kubectl + helm must be on PATH; sudo is invoked only via k3s if you use the
# `k3s kubectl` wrapper. This script uses bare kubectl, configured against
# whatever ~/.kube/config points at.

set -euo pipefail

REPO_SSH_URL="${REPO_SSH_URL:-git@github.com:coilysiren/linuxbrew-operator.git}"
REF="${REF:-main}"
NAMESPACE="${NAMESPACE:-linuxbrew-operator-system}"
RELEASE="${RELEASE:-brew-op}"
SECRET_NAME="${SECRET_NAME:-linuxbrew-operator-deploy-key}"
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-$HOME/.ssh/id_ed25519}"
KNOWN_HOSTS_TMP="$(mktemp)"
trap 'rm -f "$KNOWN_HOSTS_TMP"' EXIT

# 1. helm-git plugin. Idempotent: skip if already installed.
echo ">>> ensuring helm-git plugin is installed"
if ! helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx helm-git; then
  helm plugin install https://github.com/aslafy-z/helm-git
else
  echo "    helm-git already installed"
fi

# 2. Namespace. Idempotent via apply --dry-run | apply.
echo ">>> ensuring namespace $NAMESPACE exists"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"

# 3. Deploy-key Secret. Idempotent: replace if exists, create if not.
echo ">>> populating $KNOWN_HOSTS_TMP with github.com host keys"
ssh-keyscan github.com > "$KNOWN_HOSTS_TMP" 2>/dev/null

if [ ! -r "$SSH_PRIVATE_KEY" ]; then
  echo "ERROR: SSH private key not readable at $SSH_PRIVATE_KEY" >&2
  echo "       set SSH_PRIVATE_KEY=/path/to/key to override" >&2
  exit 1
fi

echo ">>> creating/replacing Secret $NAMESPACE/$SECRET_NAME"
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-file=ssh-privatekey="$SSH_PRIVATE_KEY" \
  --from-file=known_hosts="$KNOWN_HOSTS_TMP" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. helm upgrade --install. Idempotent. Re-running with a different REF=
#    triggers a rolling restart of the controller Pod, which reclones and
#    rebuilds against that ref.
#
# helm-git URL shape: git+ssh://git@host/owner/repo.git//path?ref=ref
# Convert "git@github.com:coilysiren/linuxbrew-operator.git" into
# "git+ssh://git@github.com/coilysiren/linuxbrew-operator.git//chart?ref=main"
# by replacing the single ":" between host and path with "/".
HOST_PATH="${REPO_SSH_URL/:/\/}"   # git@github.com/coilysiren/...
HELM_URL="git+ssh://${HOST_PATH}//chart?ref=${REF}"

echo ">>> helm upgrade --install $RELEASE $HELM_URL"
helm upgrade --install "$RELEASE" "$HELM_URL" \
  --namespace "$NAMESPACE"

echo ">>> done. Watch the controller come up:"
echo "    kubectl get pods -n $NAMESPACE -w"
echo ">>> tail logs once the manager container is past init:"
echo "    kubectl logs -n $NAMESPACE deploy/${RELEASE}-linuxbrew-operator-controller -f -c manager"
