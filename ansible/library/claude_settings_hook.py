#!/usr/bin/python
# GPL-3.0-or-later (https://www.gnu.org/licenses/gpl-3.0.txt). The /usr/bin/python
# shebang is the Ansible convention - the controller rewrites it; env-style fails.
"""Ansible module: idempotently wire one Claude Code hook into settings.json.

Ensures a single command hook is present (or absent) under a given event group
in ~/.claude/settings.json, matched by a stable `marker` substring so re-runs
are no-ops. This is the ansible-native replacement for the per-feature
scripts/install-*.py mergers (session-pulse, agent-name): same merge shape,
driven from a role instead of a shell call.

The settings file is hand-and-tool-shared (the harness, coily, and other
install scripts all touch it), so this module only adds/removes the one hook it
owns and preserves every other key verbatim. Writes are atomic (temp file +
os.replace) to avoid a torn settings.json if interrupted.

check_mode reports the would-change without writing. No secrets, no opaque
values: the only inputs are an event name, a tool matcher, and a command path.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

from ansible.module_utils.basic import AnsibleModule


def _load(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def _find_group(groups: list, matcher: str) -> dict | None:
    """Return the existing group for this matcher, or None. A group with no
    matcher key and an empty matcher arg are treated as the same bucket."""
    for group in groups:
        if group.get("matcher", "") == matcher:
            return group
    return None


def _has_marker(groups: list, marker: str) -> bool:
    for group in groups:
        for hook in group.get("hooks", []):
            if marker in hook.get("command", ""):
                return True
    return False


def _ensure_present(settings: dict, event: str, matcher: str, command: str, marker: str) -> bool:
    hooks = settings.setdefault("hooks", {})
    groups = hooks.setdefault(event, [])
    if _has_marker(groups, marker):
        return False
    entry = {"type": "command", "command": command}
    group = _find_group(groups, matcher)
    if group is None:
        new: dict = {"hooks": [entry]}
        if matcher:
            new["matcher"] = matcher
        groups.append(new)
    else:
        group.setdefault("hooks", []).append(entry)
    return True


def _ensure_absent(settings: dict, event: str, marker: str) -> bool:
    hooks = settings.get("hooks", {})
    groups = hooks.get(event, [])
    changed = False
    for group in groups:
        kept = [h for h in group.get("hooks", []) if marker not in h.get("command", "")]
        if len(kept) != len(group.get("hooks", [])):
            group["hooks"] = kept
            changed = True
    # Drop now-empty groups so we leave no dangling buckets behind.
    if changed:
        hooks[event] = [g for g in groups if g.get("hooks")]
        if not hooks[event]:
            del hooks[event]
    return changed


def _write(path: Path, settings: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".json")
    with os.fdopen(fd, "w") as handle:
        json.dump(settings, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)


def main() -> None:
    module = AnsibleModule(
        argument_spec={
            "path": {"type": "path", "default": "~/.claude/settings.json"},
            "event": {"type": "str", "required": True},
            "matcher": {"type": "str", "default": ""},
            "command": {"type": "str", "required": True},
            "marker": {"type": "str", "required": True},
            "state": {"type": "str", "default": "present", "choices": ["present", "absent"]},
        },
        supports_check_mode=True,
    )
    path = Path(os.path.expanduser(module.params["path"]))
    event = module.params["event"]
    matcher = module.params["matcher"]
    command = module.params["command"]
    marker = module.params["marker"]
    state = module.params["state"]

    settings: dict = {}
    try:
        settings = _load(path)
    except (OSError, ValueError) as exc:
        module.fail_json(msg=f"cannot read {path}: {exc}")

    if state == "present":
        changed = _ensure_present(settings, event, matcher, command, marker)
    else:
        changed = _ensure_absent(settings, event, marker)

    if changed and not module.check_mode:
        try:
            _write(path, settings)
        except OSError as exc:
            module.fail_json(msg=f"cannot write {path}: {exc}")

    module.exit_json(changed=changed, path=str(path), event=event, marker=marker, state=state)


if __name__ == "__main__":
    main()
