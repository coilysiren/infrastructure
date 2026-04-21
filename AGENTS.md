# AGENTS.md — infrastructure

The infrastructure repo is the **source of truth for homelab deploy
knowledge** across coilysiren/*.

## Primary reference

**Before touching any k3s or Tailscale or cert-manager thing, read
[`docs/k3s-deploy-notes.md`](docs/k3s-deploy-notes.md).** It covers:

- The actual `kai-server` topology (IPs, ports, traffic paths).
- The SSM parameter inventory — including which params are orphaned
  and which are load-bearing (with typo intact).
- The six GitHub repo secrets every deployable repo needs, and which
  SSM path to sync each from.
- The canonical GHA workflow, k8s manifest, and Makefile shapes —
  eco-spec-tracker is authoritative; backend set the pattern.
- Every trap we've hit across four repos (WASM `Table.grow`, MagicDNS
  hostname vs tailnet IP, `/tailscale/k3s/*` orphans, hairpin NAT,
  the 6-hour `tailscale up` hang, binaryen apt version, etc.) with
  one-line fixes.
- A first-time-setup checklist for adding a new repo to the rig.
- A triage tree for when a deploy is failing.

When you resolve a new deploy pitfall, add it to §7 and §9 of that
doc. Don't scatter fixes across individual repos' CLAUDE.md files.

## File access

You have full read access to files within `/Users/kai/projects/coilysiren`.

## Autonomy

- Read-only shell commands (`ls`, `grep`, `cat`, `git log`, `git status`,
  `aws ssm describe-parameters`, etc.) require no approval.
- Write operations on AWS resources, kubectl writes, and any change
  that would modify a running service need explicit user confirmation.
- Never print decrypted SSM values to the transcript. Pipe them
  directly into `gh secret set` or equivalent.
