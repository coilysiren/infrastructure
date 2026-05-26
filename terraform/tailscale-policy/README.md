# terraform/tailscale-policy

Owns the tailnet **policy file** (`tagOwners`, ACL rules, ssh rules, nodeAttrs) and the **per-physical-device tag assignments** enumerated in `devices.yaml`. Companion to `terraform/tailscale-devices/`, which owns the per-service auth keys for k8s sidecars.

## Two-dimensional tag model

- **Physical machines** carry `tag:server` + `tag:physical` + per-host tag (e.g. `tag:kai-server`). `tag:server` is preserved from the pre-IaC policy so the existing `tag:ci -> tag:server` ACL keeps working without edits.
- **k8s sidecars** carry `tag:k8s` + per-service tag (e.g. `tag:eco-server`) + host tag (`tag:host-kai-server` while there's only one k3s host). Managed in `terraform/tailscale-devices/`.

## Bootstrap

State is empty on first run. The `tailscale_acl.policy` resource owns the entire policy file, so it has to adopt current state before apply, otherwise apply would clobber the live policy with whatever the resource body says.

```
coily exec terraform-tailscale-policy action=init
coily exec terraform-tailscale-policy action=import-acl
coily exec terraform-tailscale-policy action=plan
```

The first `plan` after import should show only additive diffs: the new `tagOwners` entries (`tag:physical`, the four per-host tags, `tag:host-kai-server`) and the four `tailscale_device_tags.physical` assignments. Adjust `main.tf` until the diff matches what you expect, then `action=apply`.

## Updating

- Adding a new physical machine: append to `devices.yaml`, add its per-host `tagOwners` entry in `main.tf`, plan + apply.
- Editing ACL rules: edit the body of `tailscale_acl.policy` in `main.tf`. The web-console editor is no longer the source of truth; manual edits there will be wiped on the next apply.

## Provider auth

Same admin OAuth pair as the sibling tailscale modules: `/tailscale/admin/oauth-client-{id,secret}`, `all:write` scope. Wired by `scripts/k8s/terraform_tailscale_policy.py` via `tailscale_admin_oauth_env()`.
