#!/usr/bin/env python3
# claude-session-watcher.py - per-machine watcher for Claude Code session
# files. Sits inside ~/.claude/projects, listens for real file-system
# events (create / modify), and HTTP POSTs each changed session file to
# the tailnet-only session-sink Flask app on kai-server.
#
# This is component 1 of the cross-machine session-aggregation pipeline
# (coilysiren/infrastructure#224). The chain, bottom to top:
#
#   watcher (this script)  ->  session-sink Flask app  ->  repo-recall  ->  luca
#
# Runs on the 4 local environments that are NOT kai-server: Mac desktop,
# Mac laptop, Windows-native, Windows WSL. kai-server needs no watcher -
# prod repo-recall reads its sessions off local disk directly.
#
# Design notes:
#   - Event-driven, not a poll. watchdog gives real OS events (FSEvents
#     on macOS, ReadDirectoryChangesW on Windows, inotify on Linux).
#   - Per-file debounce. Session .jsonl files are appended to constantly
#     while a session is live; POSTing on every single append would be
#     needlessly chatty. We coalesce events and POST a file once it has
#     been quiet for SESSION_WATCHER_DEBOUNCE seconds.
#   - The POST is a multipart upload, NOT an scp. The sink is a dumb
#     write-only HTTP endpoint; it does not care how the file got there.
#   - Failures never crash the watcher. A file that fails to POST stays
#     dirty and is retried on the next flush tick.
#
# Config (all via environment, install scripts wire these up):
#   SESSION_SINK_URL          required. Full ingest URL of the Flask app,
#                             e.g. http://<sink-host>:<port>/ingest
#   SESSION_WATCHER_MACHINE   required. Stable machine id, e.g.
#                             kai-mac-desktop / kai-desktop-tower-wsl.
#                             Sent so the sink namespaces files per host
#                             and session UUIDs cannot collide.
#   CLAUDE_PROJECTS_DIR       optional. Defaults to ~/.claude/projects.
#   SESSION_WATCHER_DEBOUNCE  optional. Quiescence window, seconds.
#                             Default 3.0.
#   SESSION_WATCHER_TIMEOUT   optional. Per-POST timeout, seconds.
#                             Default 30.
#
# Dependencies: watchdog, requests. The install scripts provision these
# into a dedicated venv so the watcher never collides with system
# Python or another project's environment.

import argparse
import dataclasses
import logging
import os
import pathlib
import sys
import threading
import time

import requests
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

LOG = logging.getLogger("claude-session-watcher")

# Only these files are session transcripts worth shipping. Claude Code
# also drops sidecar files (lock files, bare-UUID temp files) into the
# same directories; ignore everything that is not a .jsonl.
SESSION_SUFFIX = ".jsonl"


@dataclasses.dataclass(frozen=True)
class WatcherConfig:
    """Resolved runtime config. Bundled so the worker functions take one
    argument instead of threading five through every call."""
    session_url: str
    machine: str
    projects_dir: pathlib.Path
    debounce: float
    timeout: float


class SessionHandler(FileSystemEventHandler):
    """Records every touched .jsonl path with the time it was last seen.

    The flusher thread owns the actual POSTing. This handler only ever
    marks files dirty, so a burst of inotify events is cheap.
    """

    def __init__(self, dirty: dict, lock: threading.Lock):
        self._dirty = dirty
        self._lock = lock

    def _mark(self, path: str):
        if not path.endswith(SESSION_SUFFIX):
            return
        with self._lock:
            self._dirty[path] = time.monotonic()

    def on_created(self, event):
        if not event.is_directory:
            self._mark(event.src_path)

    def on_modified(self, event):
        if not event.is_directory:
            self._mark(event.src_path)

    def on_moved(self, event):
        # A rename into the tree (atomic-write pattern) lands as a move.
        if not event.is_directory:
            self._mark(event.dest_path)


def post_file(cfg: WatcherConfig, path: pathlib.Path) -> bool:
    """POST one session file to the sink. Returns True on a 2xx."""
    try:
        relpath = path.relative_to(cfg.projects_dir).as_posix()
    except ValueError:
        # Watcher only ever sees paths under projects_dir, but be safe.
        relpath = path.name
    try:
        with path.open("rb") as fh:
            resp = requests.post(
                cfg.session_url,
                # The sink keys storage on machine + relpath, so two
                # machines with a colliding session UUID stay distinct.
                data={"machine": cfg.machine, "relpath": relpath},
                files={"file": (path.name, fh, "application/x-ndjson")},
                headers={"X-Session-Machine": cfg.machine},
                timeout=cfg.timeout,
            )
    except (OSError, requests.RequestException) as exc:
        LOG.warning("POST failed for %s: %s", relpath, exc)
        return False
    if resp.status_code >= 300:
        LOG.warning("sink rejected %s: HTTP %s %s",
                    relpath, resp.status_code, resp.text[:200])
        return False
    LOG.info("shipped %s (%d bytes)", relpath, path.stat().st_size
             if path.exists() else 0)
    return True


def flush_loop(cfg: WatcherConfig, dirty: dict, lock: threading.Lock,
               stop: threading.Event):
    """Ship files that have been quiet for `cfg.debounce` seconds.

    A file that fails to POST is left in the dirty set and retried on the
    next tick - its timestamp is not refreshed, so it stays eligible.
    """
    while not stop.is_set():
        now = time.monotonic()
        ready = []
        with lock:
            for path, last_seen in list(dirty.items()):
                if now - last_seen >= cfg.debounce:
                    ready.append(path)
        for path_str in ready:
            path = pathlib.Path(path_str)
            if not path.exists():
                # Session file deleted before it settled; drop it.
                with lock:
                    dirty.pop(path_str, None)
                continue
            if post_file(cfg, path):
                with lock:
                    dirty.pop(path_str, None)
        stop.wait(1.0)


def initial_sweep(dirty: dict, lock: threading.Lock,
                  projects_dir: pathlib.Path):
    """Mark every pre-existing session file dirty on startup.

    Without this, a fresh install would only ever ship sessions touched
    after the watcher came up - every session from before launch would
    be invisible to the pipeline until its next edit.
    """
    count = 0
    for path in projects_dir.rglob(f"*{SESSION_SUFFIX}"):
        with lock:
            # Backdate so the first flush tick ships them immediately.
            dirty[str(path)] = time.monotonic() - 3600
        count += 1
    LOG.info("initial sweep queued %d existing session file(s)", count)


def load_config():
    """Resolve config from the environment. Returns a WatcherConfig, or
    None after logging what is missing."""
    session_url = os.environ.get("SESSION_SINK_URL", "").strip()
    machine = os.environ.get("SESSION_WATCHER_MACHINE", "").strip()
    if not session_url:
        LOG.error("SESSION_SINK_URL is unset. Point it at the session-sink "
                  "ingest endpoint, e.g. http://<sink-host>:<port>/ingest")
        return None
    if not machine:
        LOG.error("SESSION_WATCHER_MACHINE is unset. Set a stable machine "
                  "id, e.g. kai-mac-desktop")
        return None

    default_projects = pathlib.Path.home() / ".claude" / "projects"
    projects_dir = pathlib.Path(
        os.environ.get("CLAUDE_PROJECTS_DIR", str(default_projects))
    ).expanduser()
    if not projects_dir.is_dir():
        LOG.error("Claude projects dir %s does not exist", projects_dir)
        return None

    return WatcherConfig(
        session_url=session_url,
        machine=machine,
        projects_dir=projects_dir,
        debounce=float(os.environ.get("SESSION_WATCHER_DEBOUNCE", "3.0")),
        timeout=float(os.environ.get("SESSION_WATCHER_TIMEOUT", "30")),
    )


def run_once(cfg: WatcherConfig, dirty: dict) -> int:
    """Smoke-test path: ship whatever the sweep queued, then exit. No
    observer, no debounce, no flusher thread."""
    shipped = failed = 0
    for path_str in list(dirty):
        path = pathlib.Path(path_str)
        if not path.exists():
            continue
        if post_file(cfg, path):
            shipped += 1
        else:
            failed += 1
    LOG.info("--once done: %d shipped, %d failed", shipped, failed)
    return 1 if failed else 0


def run_watch(cfg: WatcherConfig, dirty: dict, lock: threading.Lock) -> int:
    """Long-lived path: an observer marks files dirty, a flusher thread
    ships them. Runs until interrupted."""
    stop = threading.Event()
    observer = Observer()
    observer.schedule(SessionHandler(dirty, lock), str(cfg.projects_dir),
                      recursive=True)
    observer.start()

    flusher = threading.Thread(
        target=flush_loop, args=(cfg, dirty, lock, stop), daemon=True)
    flusher.start()

    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        LOG.info("shutting down")
    finally:
        stop.set()
        observer.stop()
        observer.join(timeout=5)
        flusher.join(timeout=5)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--no-initial-sweep", action="store_true",
        help="skip shipping session files that already exist at startup")
    parser.add_argument(
        "--once", action="store_true",
        help="run the initial sweep, flush once, and exit (for testing)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    cfg = load_config()
    if cfg is None:
        return 2

    LOG.info("watching %s -> %s as machine=%s (debounce=%.1fs)",
             cfg.projects_dir, cfg.session_url, cfg.machine, cfg.debounce)

    dirty: dict = {}
    lock = threading.Lock()

    if not args.no_initial_sweep:
        initial_sweep(dirty, lock, cfg.projects_dir)

    if args.once:
        return run_once(cfg, dirty)
    return run_watch(cfg, dirty, lock)


if __name__ == "__main__":
    sys.exit(main())
