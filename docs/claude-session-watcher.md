# Claude session watcher

Per-machine watcher that ships Claude Code session files to a central
sink so every machine's sessions are queryable from one place.

This is component 1 of the cross-machine session-aggregation pipeline.
Tracker: [coilyco-flight-deck/infrastructure#224](https://github.com/coilyco-flight-deck/infrastructure/issues/224).

## Why

Kai runs ~10 concurrent Claude sessions across 5 environments. A session
has no visibility into what concurrent sessions are doing. The pipeline
fixes that by making every machine's sessions land in one repo-recall
DB. The chain, bottom to top:

```
watcher  ->  session-sink Flask app  ->  repo-recall  ->  luca query-sessions
(this)       (new repo, kai-server)      (multi-dir)      (hydrates "which machine")
```

The watcher is the bottom rung. It lives on each machine, notices when a
session file changes, and POSTs it to the sink.

## Where it runs

Four local environments, all NOT kai-server:

- Mac desktop - launchd agent
- Mac laptop - launchd agent
- Windows native - Scheduled Task
- Windows WSL - systemd unit

kai-server runs no watcher. Prod repo-recall reads kai-server's session
files off local disk directly.

## What it does

- Watches `~/.claude/projects` (recursively) for real file-system events
  via `watchdog` - FSEvents on macOS, ReadDirectoryChangesW on Windows,
  inotify on Linux. Event-driven, not a poll.
- Coalesces events per file. A session `.jsonl` is appended to constantly
  while live, so the watcher waits for a quiescence window
  (`SESSION_WATCHER_DEBOUNCE`, default 3s) before shipping.
- On startup, sweeps every pre-existing `.jsonl` so a fresh install
  backfills instead of only seeing sessions touched after launch.
- POSTs each file as a multipart upload. A failed POST leaves the file
  queued and retries on the next tick. Failures never crash the watcher.

## The POST contract

The watcher sends a `multipart/form-data` POST to `SESSION_SINK_URL`:

- Form field `machine` - the stable machine id (`SESSION_WATCHER_MACHINE`).
- Form field `relpath` - path of the session file relative to
  `~/.claude/projects`, posix-style (e.g.
  `-Users-kai-projects-foo/abc123.jsonl`).
- File part `file` - the raw `.jsonl`, content-type `application/x-ndjson`.
- Header `X-Session-Machine` - same value as the `machine` field.

The sink is expected to store each upload at `<machine>/<relpath>` so two
machines with a colliding session UUID stay distinct. Any 2xx is success.
This contract is what the session-sink Flask app must implement.

## Config

All via environment. The install scripts wire these up.

- `SESSION_SINK_URL` - required. Full ingest URL, e.g.
  `http://<sink-host>:<port>/ingest`. Embeds a tailnet FQDN (an opaque
  id), so it is resolved from SSM (`/coilysiren/session-sink/url`) at
  install time and never committed.
- `SESSION_WATCHER_MACHINE` - required. Stable machine id, e.g.
  `kai-mac-desktop`, `kai-desktop-tower-wsl`.
- `CLAUDE_PROJECTS_DIR` - optional. Defaults to `~/.claude/projects`.
- `SESSION_WATCHER_DEBOUNCE` - optional. Quiescence window, seconds.
  Default `3.0`.
- `SESSION_WATCHER_TIMEOUT` - optional. Per-POST timeout, seconds.
  Default `30`.

## Install

Each installer provisions a dedicated `uv` venv (watchdog + requests) so
the watcher never collides with system Python. Re-run any installer to
upgrade.

Mac (desktop or laptop):

```
scripts/claude-session-watcher-install-mac.sh --machine kai-mac-desktop
scripts/claude-session-watcher-install-mac.sh --uninstall
```

Linux / WSL:

```
bash scripts/claude-session-watcher-install.sh --machine kai-desktop-tower-wsl
bash scripts/claude-session-watcher-install.sh --uninstall
```

Windows native (non-elevated PowerShell):

```
scripts\claude-session-watcher-install-windows.ps1 -Machine kai-desktop-tower-native
scripts\claude-session-watcher-install-windows.ps1 -Uninstall
```

All three resolve `SESSION_SINK_URL` from SSM, or take it from the
`SESSION_SINK_URL` env var / `-SinkUrl` flag. Until the session-sink
Flask app ships and `/coilysiren/session-sink/url` exists, pass the URL
explicitly.

## Smoke test

Run one sweep-and-ship pass without installing anything:

```
SESSION_SINK_URL=http://localhost:9999/ingest \
SESSION_WATCHER_MACHINE=test \
uv run python scripts/claude-session-watcher.py --once
```

## Verify a live install

- Mac: `launchctl list | grep claude-session-watcher`, then
  `tail -f ~/Library/Logs/claude-session-watcher.log`.
- Linux / WSL: `journalctl -u claude-session-watcher.service -f`.
- Windows: `Get-ScheduledTask -TaskName ClaudeSessionWatcher | Get-ScheduledTaskInfo`.
