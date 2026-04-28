#!/usr/bin/env bash
# Pull the latest release zip(s) of an Eco mod from GitHub and unzip
# them into the EcoServer Mods tree. Generalizes the old install-eco-
# telemetry.sh: takes the mod NAME as the only positional arg.
#
# For each repo in {coilysiren/eco-mods, coilysiren/eco-mods-public,
# coilysiren/NAME} (whichever exist and have releases), look at the
# latest release for assets matching NAME-*.zip, download every match,
# and unzip -o each one into $SERVER_DIR. unzip -o handles the merge
# case where the same mod ships split across two repos (e.g. Librarian).
#
# Run as kai (or whichever user owns the EcoServer tree). No root
# needed: everything lives under /home/kai/.
#
# Argv: install-eco-mod.sh NAME

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: install-eco-mod.sh NAME" >&2
  exit 2
fi

NAME="$1"

# Defensive: coily already validates NAME, but the script is also
# runnable by hand and the rest of it interpolates NAME into curl URLs
# and shell glob matches.
if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$NAME" == -* ]]; then
  echo "install-eco-mod: NAME '$NAME' rejected (letters/digits/._- only, no leading dash)" >&2
  exit 2
fi

SERVER_DIR="/home/kai/Steam/steamapps/common/EcoServer"
if [[ ! -d "$SERVER_DIR" ]]; then
  echo "EcoServer dir not found at $SERVER_DIR" >&2
  exit 1
fi

# Cruft from the pre-2026-04-28 EcoTelemetry zip layout (top-level
# EcoTelemetry/ instead of Mods/EcoTelemetry/). Eco never loaded it.
# Remove on sight whenever we deploy that mod.
if [[ "$NAME" == "EcoTelemetry" && -e "$SERVER_DIR/EcoTelemetry" && ! -L "$SERVER_DIR/EcoTelemetry" ]]; then
  echo ">>> removing stale $SERVER_DIR/EcoTelemetry (wrong-layout cruft)"
  rm -rf "$SERVER_DIR/EcoTelemetry"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Repos that may publish a release asset for this mod. Order is only a
# tiebreaker: when the same filename ships from multiple repos, the
# later download overwrites the earlier one (unzip -o is idempotent).
REPOS=("coilysiren/eco-mods" "coilysiren/eco-mods-public" "coilysiren/$NAME")

found_any=0
declare -A seen=()

for repo in "${REPOS[@]}"; do
  if [[ -n "${seen[$repo]:-}" ]]; then
    continue
  fi
  seen[$repo]=1

  echo ">>> querying $repo for $NAME-*.zip in latest release"
  api_url="https://api.github.com/repos/$repo/releases/latest"

  # 404 (no releases / no repo) is expected for the speculative
  # coilysiren/NAME probe; -f turns those into a non-zero exit we can
  # ignore without aborting the loop.
  body="$(curl -sfL "$api_url" 2>/dev/null || true)"
  if [[ -z "$body" ]]; then
    echo "    no latest release on $repo, skipping"
    continue
  fi

  asset_urls="$(printf '%s' "$body" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | grep -E "/${NAME}-[^/]*\.zip$" || true)"

  if [[ -z "$asset_urls" ]]; then
    echo "    no $NAME-*.zip asset on $repo, skipping"
    continue
  fi

  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    fname="$(basename "$url")"
    echo ">>> downloading $fname from $repo"
    curl -sfL -o "$tmp/$fname" "$url"
    echo ">>> unzipping $fname into $SERVER_DIR"
    (cd "$SERVER_DIR" && unzip -o "$tmp/$fname")
    found_any=1
  done <<< "$asset_urls"
done

if [[ $found_any -eq 0 ]]; then
  echo "install-eco-mod: no $NAME-*.zip asset found across ${REPOS[*]}" >&2
  exit 1
fi

echo ">>> done. server not restarted; run 'coily eco restart' when ready."
