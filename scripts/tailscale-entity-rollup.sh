#!/usr/bin/env bash
# Count tailnet entities sliced five ways via `coily tailscale`. Four are disjoint and sum
# to the total. by_tag overlaps and the rollup reconciles it. See docs/tailscale.md.

# Output is colorized YAML via bat (plain when piped to a file), cat fallback. Runs from
# any cwd. Usage: scripts/tailscale-entity-rollup.sh [> out.yaml].
set -euo pipefail

colorize() {
  if command -v bat >/dev/null 2>&1; then
    bat -l yaml --style=plain --paging=never
  else
    cat
  fi
}

coily tailscale status --json 2>/dev/null | jq -r '
  ([.Self] + [.Peer[]])                              as $nodes
  | ($nodes | length)                                as $total
  # real humans: tailnet users whose login is an email address
  | ([.User[] | select(.LoginName | test("@"))])     as $people
  | ($nodes | map(select((.Tags // []) | any(.=="tag:physical")))) as $physical
  | ($nodes | map(select((.Tags // []) | any(. == "tag:k8s" or . == "tag:k8s-operator")))) as $k8s
  | ($nodes | map(select((.Tags // []) | length == 0))) as $untagged
  | ($nodes | map(select((.Tags // []) | length  > 0))) as $tagged
  | ($nodes | map(.Tags // []) | add // [])          as $tagrefs
  | ($tagrefs | length)                              as $tagref_count
  | ($tagged  | map(select((.Tags|length) > 1)) | length) as $multitag
  | "# tailscale entity rollup",
    "total_nodes: \($total)",
    "people: \($people | length)",
    "",
    "# by_type - disjoint, sums to total_nodes",
    "by_type:",
    "  * people - \($people | length) - \($people | map(.LoginName | (.[0:1]) + "***@" + (split("@")[1])) | join(", "))",
    "  * physical_machines - \($physical | length) - tag:physical",
    "  * k8s_workloads - \($k8s | length) - tag:k8s + tag:k8s-operator",
    "  * personal_devices - \($untagged | length) - untagged, owned by a user",
    "",
    "# by_os - disjoint, sums to total_nodes",
    "by_os:",
    ( $nodes | group_by(.OS) | sort_by(-length)
        | .[] | "  * \(.[0].OS) - \(length)" ),
    "",
    "# by_online - disjoint, sums to total_nodes",
    "by_online:",
    "  * online - \($nodes | map(select(.Online)) | length)",
    "  * offline - \($nodes | map(select(.Online | not)) | length)",
    "",
    "# by_tag - OVERLAPPING, a node can carry several tags",
    "by_tag:",
    ( $tagrefs | group_by(.) | sort_by(-length)
        | .[] | "  * \(.[0]) - \(length)" ),
    "",
    "# roll-up - reconciles the overlap",
    "rollup:",
    "  * total_nodes - \($total) - distinct tailnet machines",
    "  * tagged_nodes - \($tagged | length) - carry at least one tag",
    "  * untagged_nodes - \($untagged | length) - personal devices, no tags",
    "  * tag_assignments - \($tagref_count) - tag refs across tagged nodes (> tagged_nodes due to multi-tag)",
    "  * multi_tagged_nodes - \($multitag) - nodes counted in more than one by_tag bucket"
' | colorize
