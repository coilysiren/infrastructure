#!/usr/bin/env bash
# Download an Eco mod's latest NAME-*.zip release assets from the candidate repos and
# unzip -o each into the EcoServer Mods tree. See docs/eco-server-setup.md.

# unzip -o merges mods split across repos. Runs as kai, no root.
# Argv: install-eco-mod.sh NAME.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: install-eco-mod.sh NAME" >&2
  exit 2
fi

NAME="$1"

# Defensive re-validation: coily checks NAME, but this is also hand-runnable and NAME
# gets interpolated into curl URLs and globs.
if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$NAME" == -* ]]; then
  echo "install-eco-mod: NAME '$NAME' rejected (letters/digits/._- only, no leading dash)" >&2
  exit 2
fi

SERVER_DIR="/home/kai/Steam/steamapps/common/EcoServer"
if [[ ! -d "$SERVER_DIR" ]]; then
  echo "EcoServer dir not found at $SERVER_DIR" >&2
  exit 1
fi

# Remove stale top-level EcoTelemetry/ cruft from the pre-2026-04-28 zip layout
# (Eco never loaded it) on sight whenever we deploy that mod.
if [[ "$NAME" == "EcoTelemetry" && -e "$SERVER_DIR/EcoTelemetry" && ! -L "$SERVER_DIR/EcoTelemetry" ]]; then
  echo ">>> removing stale $SERVER_DIR/EcoTelemetry (wrong-layout cruft)"
  rm -rf "$SERVER_DIR/EcoTelemetry"
fi

# The AutoGen-orphan sweep moved to eco-cycle-prep/mods.sweep_autogen_on_server
# (runs after coily mods-sync/mods-disable, or coily mods-sweep). See eco-cycle-prep#5.

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Candidate repos for this mod's release asset. Order is just a tiebreaker (later
# overwrites earlier, unzip -o). Probe both PascalCase and kebab-case per-mod repos.
NAME_KEBAB="$(printf '%s' "$NAME" | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' | tr '[:upper:]' '[:lower:]')"
REPOS=("coilyco-bridge/eco-mods" "coilyco-flight-deck/eco-mods-public" "coilysiren/$NAME" "coilysiren/$NAME_KEBAB")

found_any=0
declare -A seen=()

for repo in "${REPOS[@]}"; do
  if [[ -n "${seen[$repo]:-}" ]]; then
    continue
  fi
  seen[$repo]=1

  echo ">>> querying $repo for $NAME-*.zip in latest release"
  api_url="https://api.github.com/repos/$repo/releases/latest"

  # 404 is expected for the speculative coilysiren/NAME probe. -f makes that a
  # non-zero exit we ignore without aborting the loop.
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

# OTel .NET self-diagnostics: the SDK reads OTEL_DIAGNOSTICS.json from the process CWD
# and dumps otherwise-swallowed export errors to LogDirectory. See eco-telemetry#5.
if [[ "$NAME" == "EcoTelemetry" ]]; then
  diag="$SERVER_DIR/OTEL_DIAGNOSTICS.json"
  log_dir="$SERVER_DIR/Logs/EcoTelemetry"
  mkdir -p "$log_dir"
  cat > "$diag" <<'JSON'
{
  "LogDirectory": "/home/kai/Steam/steamapps/common/EcoServer/Logs/EcoTelemetry",
  "FileSize": 32768,
  "LogLevel": "Verbose"
}
JSON
  echo ">>> wrote $diag (OTel self-diagnostics -> $log_dir)"

  # Force EmitConsoleAlongsideOtlp=true while #5 is open. jq is idempotent;
  # if the field is already true this is a no-op.
  live_cfg="$SERVER_DIR/Configs/EcoTelemetry.json"
  if [[ -f "$live_cfg" ]] && command -v jq >/dev/null; then
    tmp="$(mktemp)"
    if jq '.EmitConsoleAlongsideOtlp = true' "$live_cfg" > "$tmp"; then
      mv "$tmp" "$live_cfg"
      echo ">>> set EmitConsoleAlongsideOtlp=true in $live_cfg"
    else
      rm -f "$tmp"
    fi
  fi
fi

echo ">>> done. server not restarted; run 'coily eco restart' when ready."
