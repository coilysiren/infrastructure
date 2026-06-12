# Tailscale tailnet module

`terraform/tailscale/` owns the tailnet: the full ACL policy, per-physical device tags, per-service auth keys, and the SSM params holding those keys.

## Topology

- `tailscale_acl.policy` carries the **full tailnet ACL** (groups, tagOwners, acls, ssh, nodeAttrs). The resource is a singleton in the Tailscale provider - applying it replaces the entire policy document. All tailnet edits go through this module; the admin console is read-only from here on.
- `tailscale_device_tags.physical` per physical host, driven by `devices.yaml`. A host needs `tag:physical` there to be SSH-reachable from the other physicals (the `tag:physical -> tag:physical` ssh rule). Tagging requires the device to be user-authed at tag time.
- `tailscale_tailnet_key.service` per k3s service, driven by `services.yaml`, stashed to `/coilysiren/<service>/ts-authkey` for the in-Pod sidecars.

## Admin credentials (operator-held, per-apply)

The module needs admin scope on api.tailscale.com to rewrite the ACL. The credential is **operator-held only - never SSM, never any agent-readable store**. The tailnet ACL is the boundary that decides which machines an agent can SSH into, so its write credential must not be readable by the agents operating under that boundary. (It previously lived at `/tailscale/admin/oauth-client-{id,secret}` under `alias/admin-only`; that pattern is retired and the params are gone.)

Easy default - a personal access token from Kai's admin account:

1. Generate at <https://login.tailscale.com/admin/settings/keys> -> **Generate access token**. Pick a short expiry, the token only needs to outlive the apply session.
2. Export it in the shell that runs the verb:
   ```
   export TAILSCALE_API_KEY=FILL_ME_IN
   ```
3. Run the module verbs (below), then close the shell. Revoke the token in the console if it has life left.

Alternative - an OAuth client (`all:write`) from <https://login.tailscale.com/admin/settings/trust-credentials>, exported as `TAILSCALE_OAUTH_CLIENT_ID` + `TAILSCALE_OAUTH_CLIENT_SECRET`. Same handling, two halves instead of one. The wrapper accepts either form; the provider's `scopes` argument only applies to the OAuth flow and is inert under api-key auth.

Distinct from the runtime CI OAuth clients under `/tailscale/oauth/<service>/` (narrow scopes) - those stay in SSM because they can't rewrite policy.

## Module

`terraform/tailscale/`. Kai runs it (the env carries the admin credential, so this is a human-driven verb, not an agent one):

```
ward exec terraform-tailscale action=init
ward exec terraform-tailscale action=plan
ward exec terraform-tailscale action=apply
```

The wrapper validates that `TAILSCALE_API_KEY` (or the OAuth pair) is exported and hands the env to terraform. State at `s3://coilysiren-assets/terraform-state/infrastructure/tailscale.tfstate` (native lockfile, same shape as `terraform/grafana/`).

Adding a physical host: add it to `devices.yaml` with `tag:physical` plus a `tag:<hostname>` entry, register the new tag in `tagOwners` in `main.tf`, apply. Adding a k3s service: append to `services.yaml`, apply, wire the ExternalSecret to the minted `/coilysiren/<service>/ts-authkey`.

## Host-side prereqs on kai-server

Not managed by this module:

1. `sudo tailscale set --ssh` - enables Tailscale SSH (off by default).
2. `kai-server` advertises `tag:homelab`. Approve in admin console after ACL applies.
3. `deploy` user + narrow sudo:
   ```
   sudo useradd -m -s /bin/bash deploy
   sudo tee /etc/sudoers.d/deploy-k3s <<'EOF'
   deploy ALL=(ALL) NOPASSWD: /usr/local/bin/k3s ctr -n k8s.io images import -
   EOF
   sudo chmod 0440 /etc/sudoers.d/deploy-k3s
   ```
4. Kubeconfig for `deploy`:
   ```
   sudo install -d -o deploy -g deploy /home/deploy/.kube
   sudo install -m 600 -o deploy -g deploy /etc/rancher/k3s/k3s.yaml /home/deploy/.kube/config
   ```

## Retired: GHA -> Tailscale OIDC

The module used to mint one `tailscale_federated_identity` per deployable repo (from `repos.yaml`) so GitHub Actions could join the tailnet as `tag:ci` via OIDC, plus a `sync-tailscale-oidc-secrets` verb pushing `TS_CLIENT_ID` / `TS_AUDIENCE` to each repo. GitHub Actions no longer joins the tailnet, so the identities were deleted console-side and the resources, `repos.yaml`, and the sync verb are gone. The `tag:ci` / `group:ci` ACL rules linger pending a follow-up audit. History: [coilyco-flight-deck/infrastructure#177](https://github.com/coilyco-flight-deck/infrastructure/issues/177).

## See also

- [docs/k3s-deploy-notes.md](k3s-deploy-notes.md) - homelab topology, SSM inventory.
