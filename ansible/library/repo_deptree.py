#!/usr/bin/python
# GPL-3.0-or-later (https://www.gnu.org/licenses/gpl-3.0.txt). The /usr/bin/python
# shebang is the Ansible convention - the controller rewrites it; env-style fails.
"""Ansible module: validate the cross-org repo dependency tree.

Step 8 of the up-to-date.py port. Walks the `dependsOn` edges of
catalog-graph.json, maps each endpoint to its bridge/flight-deck/stay/archive
bucket from repo-split-decisions.yaml, and FAILs on any flight-deck -> bridge
edge (the cross-org rule: an external-facing repo must not depend on one of
Kai's private tools). Read-only - check mode and apply mode are identical.

repo-split-decisions.yaml is hand-parsed (stdlib only, no PyYAML dependency in
the module): the `decisions:` block holds 2-space `<name>:` keys each carrying
a 4-space `bucket: <x>`.

No opaque values and no secrets: reads two local data files.
"""
from __future__ import annotations

import json
import os
import re

from ansible.module_utils.basic import AnsibleModule


def _node_name(node_id):
    """Last path segment of a catalog node id (the repo name)."""
    return node_id.rstrip("/").rsplit("/", 1)[-1]


def _load_buckets(path):
    """repo name -> bucket from the `decisions:` block of the decisions YAML."""
    buckets = {}
    in_decisions = False
    current = None
    with open(path, encoding="utf-8") as handle:
        for line in handle.read().splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if not line.startswith(" "):  # a top-level key
                in_decisions = line.startswith("decisions:")
                current = None
                continue
            if not in_decisions:
                continue
            if (m := re.match(r"^  ([\w.\-]+):\s*$", line)):
                current = m.group(1)
            elif current and (m := re.match(r"^    bucket:\s*([\w\-]+)", line)):
                buckets[current] = m.group(1)
                current = None
    return buckets


def run_module():
    module = AnsibleModule(
        argument_spec={
            "catalog_graph": {"type": "path", "required": True},
            "split_decisions": {"type": "path", "required": True},
        },
        supports_check_mode=True,
    )
    p = module.params
    graph_path, decisions_path = p["catalog_graph"], p["split_decisions"]

    if not os.path.exists(graph_path):
        module.exit_json(changed=False, validated=False, violations=[],
                         summary=f"{os.path.basename(graph_path)} absent - run build-catalog-graph first")
    if not os.path.exists(decisions_path):
        module.exit_json(changed=False, validated=False, violations=[],
                         summary=f"{os.path.basename(decisions_path)} absent - dep tree not validated")

    graph = {}
    try:
        with open(graph_path, encoding="utf-8") as handle:
            graph = json.load(handle)
    except (ValueError, OSError) as exc:
        module.fail_json(msg=f"catalog-graph.json unparseable: {exc}")

    buckets = _load_buckets(decisions_path)
    if not buckets:
        module.exit_json(changed=False, validated=False, violations=[],
                         summary="no buckets parsed from decisions YAML - dep tree not validated")

    edges = [e for e in graph.get("edges", []) if e.get("type") == "dependsOn"]
    violations = []
    unknown = set()
    for e in edges:
        frm, to = _node_name(e.get("from", "")), _node_name(e.get("to", ""))
        fb, tb = buckets.get(frm), buckets.get(to)
        if fb is None:
            unknown.add(frm)
        if tb is None:
            unknown.add(to)
        # The rule: a flight-deck repo must not depend on a bridge repo.
        if fb == "flight-deck" and tb == "bridge":
            violations.append(f"{frm} (flight-deck) -> {to} (bridge)")

    if violations:
        summary = (f"{len(violations)} flight-deck->bridge edge(s) across {len(edges)} "
                   "dependsOn edges - fix bucket or repoint dep")
    else:
        summary = f"clean - 0 flight-deck->bridge edges across {len(edges)} dependsOn edges"

    module.exit_json(
        changed=False,
        validated=True,
        violations=violations,
        unknown=sorted(unknown),
        edge_count=len(edges),
        summary=summary,
    )


if __name__ == "__main__":
    run_module()
