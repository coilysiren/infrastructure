---
name: ops-investigation-k3s-pod-eviction
description: Diagnose silent pod evictions on the kai-server k3s cluster. Walks events, describe output, node taints, OOM kills, ephemeral-storage pressure, image-pull failures, and QoS-class evictions in a top-down order. Aliases - k3s eviction, pod eviction, pod evicted, why was my pod evicted, kubelet eviction, k3s pod eviction, k3s-pod-eviction-diagnosis, evicted pod debug, pod disappeared, pod restart loop.
---

# k3s pod eviction diagnosis

Status: 🛠 Runbook | Last updated: 2026-05-08

## Overview

Runbook for the "my pod was evicted and I don't know why" case on
kai-server. Walks the standard kubelet eviction signals top-down so
the actual cause shows up before guesswork starts.

**Why a runbook and not a script:** kubelet eviction reasons split into
distinct branches with different remediations. Mechanical inspection
(get events / describe / get node) is the wrong abstraction layer to
automate; the value is in the branching, not the kubectl calls.

## Procedure

All `kubectl` reads route through coily for the audit log:
`coily ops kubectl --context=kai-server <args>`.

1. **Confirm the eviction.**

   ```sh
   coily ops kubectl --context=kai-server get events --sort-by='.lastTimestamp' --all-namespaces | grep -i evict
   ```

   Note the pod name, namespace, and Reason. Reason is load-bearing:
   `Evicted`, `OOMKilled`, `NodeNotReady`, `DiskPressure`,
   `MemoryPressure`.

2. **Describe the pod, even if terminated.**

   ```sh
   coily ops kubectl --context=kai-server -n <ns> describe pod <pod>
   ```

   Look at: Last State (with exit code), Conditions, Events kept on
   the pod object briefly.

3. **Describe the node it was on.**

   ```sh
   coily ops kubectl --context=kai-server describe node <node>
   ```

   Look at: Conditions (DiskPressure, MemoryPressure, PIDPressure,
   Ready), Allocatable vs Allocated capacity, Taints.

4. **Branch by Reason.**

   - **OOMKilled** - container exceeded its memory limit. Pull
     `kubectl top pod` history if metrics-server is up; otherwise
     check Sentry for the workload (process-memory-heartbeat). Fix is
     usually bumping the limit or finding the leak.
   - **DiskPressure** / **MemoryPressure** - node-level pressure.
     Check `journalctl -u k3s` on kai-server (`coily ops ssh kai-server`)
     for kubelet eviction-manager logs. Fix is image-prune or
     freeing local storage.
   - **NodeNotReady** / connection refused - infra-side. Check whether
     kai-server is healthy, k3s service running, network reachable.
     `coily-passthroughs` documents the ssh allow-list.
   - **Evicted** with no specific Reason - kubelet QoS-class eviction
     under pressure. BestEffort pods evict first. Either move to
     Burstable / Guaranteed by setting requests, or accept the pod
     is best-effort.
   - **ImagePullBackOff masquerading as eviction** - if the pod
     entered CrashLoopBackOff after image issues, look for
     ErrImagePull events and fix at the registry side first.

5. **Write up the cause.**

   Even after the immediate fire is out, jot the cause + remediation
   into the daily-operational inbox synthesis so the pattern is
   visible the next time.

## Notes

- The `kai-server` context is Tailscale-reachable; if it's not,
  diagnosis stops here and the problem is networking, not the pod.
- Custom systemd ExecStart args on kai-server are documented under
  `k3s-upgrade-homelab` - relevant if a recent upgrade may have
  dropped flags that the pod depended on.
- This skill is a peer to `coilyco-ops-investigation` - that meta-skill
  routes here when the words "pod evicted" or "k3s eviction" appear.
