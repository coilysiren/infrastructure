# Agent instructions

See `../AGENTS.md` for workspace-level conventions (git workflow, test/lint autonomy, readonly ops, writing voice, deploy knowledge). This file covers only what's specific to this repo.

**Exception:** confirm before `git push`, before any AWS SSM / kubectl / cloud write, and never print decrypted SSM values. These ops are migrating to the `coily` CLI.

---

The infrastructure repo is the **source of truth for homelab deploy knowledge** across coilysiren/*.

## Primary reference

**Before touching any k3s or Tailscale or cert-manager thing, read [`docs/k3s-deploy-notes.md`](docs/k3s-deploy-notes.md).** It covers:

- The actual `kai-server` topology (IPs, ports, traffic paths).
- The SSM parameter inventory - including which params are orphaned and which are load-bearing (with typo intact).
- The six GitHub repo secrets every deployable repo needs, and which SSM path to sync each from.
- The canonical GHA workflow, k8s manifest, and Makefile shapes - eco-spec-tracker is authoritative; backend set the pattern.
- Every trap we've hit across four repos (WASM `Table.grow`, MagicDNS hostname vs tailnet IP, `/tailscale/k3s/*` orphans, hairpin NAT, the 6-hour `tailscale up` hang, binaryen apt version, etc.) with one-line fixes.
- A first-time-setup checklist for adding a new repo to the rig.
- A triage tree for when a deploy is failing.

When you resolve a new deploy pitfall, add it to §7 and §9 of that doc. Don't scatter fixes across individual repos' AGENTS.md files.

## Write-op discipline

Never print decrypted SSM values to the transcript. Pipe them directly into `gh secret set` or equivalent. Reach for the `coily` CLI before raw `aws` / `kubectl` whenever possible - these ops are migrating there.
