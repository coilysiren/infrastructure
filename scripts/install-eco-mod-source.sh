#!/usr/bin/env bash
# Deploy a source-tree Eco mod by rsyncing Mods/UserCode/NAME or Mods/NAME from the
# eco-mods{,-public} checkouts into the EcoServer Mods tree. See docs/eco-server-setup.md.

# Both repos apply in order (no --delete, so a cross-repo split survives). Runs as kai,
# no root. Argv: install-eco-mod-source.sh NAME.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: install-eco-mod-source.sh NAME" >&2
  exit 2
fi

NAME="$1"

if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$NAME" == -* ]]; then
  echo "install-eco-mod-source: NAME '$NAME' rejected (letters/digits/._- only, no leading dash)" >&2
  exit 2
fi

SERVER_DIR="/home/kai/Steam/steamapps/common/EcoServer"
if [[ ! -d "$SERVER_DIR" ]]; then
  echo "EcoServer dir not found at $SERVER_DIR" >&2
  exit 1
fi

REPOS_ROOT="/home/kai/projects/coilysiren"
SOURCE_REPOS=("eco-mods" "eco-mods-public")

found_any=0

for repo in "${SOURCE_REPOS[@]}"; do
  repo_dir="$REPOS_ROOT/$repo"
  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "    $repo not cloned at $repo_dir, skipping"
    continue
  fi

  echo ">>> fast-forwarding $repo"
  if ! git -C "$repo_dir" pull --ff-only; then
    echo "!!! git pull --ff-only failed in $repo_dir" >&2
    exit 1
  fi

  for sub in "Mods/UserCode/$NAME" "Mods/$NAME"; do
    src="$repo_dir/$sub"
    if [[ ! -d "$src" ]]; then
      continue
    fi
    parent_rel="$(dirname "$sub")"
    dest_parent="$SERVER_DIR/$parent_rel"
    mkdir -p "$dest_parent"
    echo ">>> rsync $repo/$sub -> $dest_parent/$NAME/"
    # Trailing slash on src copies *contents* into <dest>/<NAME>/.
    rsync -a --human-readable "$src/" "$dest_parent/$NAME/"
    found_any=1
  done
done

if [[ $found_any -eq 0 ]]; then
  echo "install-eco-mod-source: no Mods/UserCode/$NAME or Mods/$NAME found in ${SOURCE_REPOS[*]}" >&2
  exit 1
fi

echo ">>> done. server not restarted; run 'coily eco restart' when ready."
