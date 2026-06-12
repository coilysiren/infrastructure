# Tailscale OIDC for CI deploys

Per-repo federated identities, no long-lived shared OAuth secret. Tracker: [coilyco-flight-deck/infrastructure#177](https://github.com/coilyco-flight-deck/infrastructure/issues/177).

## Why

Today every deployable repo carries the same `/tailscale/oauth-client-id` + `/tailscale/oath-secret` (typo) pair, synced to GH repo secrets. One leak grants `tag:ci` to every repo until manual rotation. Federated identity flips this: GitHub Actions mints a short-lived OIDC token, Tailscale verifies the subject claim, and only the matching `client_id` + `audience` ever sits in the repo. No long-lived bearer.

## Topology

- `tailscale_federated_identity` per repo, keyed by repo name. Subject `repo:coilysiren/<name>:ref:refs/heads/main`, scope `auth_keys`, tags `["tag:ci"]`.
- `github_actions_secret.TS_CLIENT_ID` and `TS_AUDIENCE` per repo.
- `tailscale_acl.policy` carries the **full tailnet ACL** (groups, tagOwners, acls, ssh, nodeAttrs). The resource is a singleton in the Tailscale provider - applying it replaces the entire policy document. All tailnet edits go through this module; the admin console is read-only from here on.

Workflow side:

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: tailscale/github-action@v4
    with:
      oauth-client-id: ${{ secrets.TS_CLIENT_ID }}
      audience: ${{ secrets.TS_AUDIENCE }}
      tags: tag:ci
      use-cache: 'true'
```

## Admin credentials (operator-held, per-apply)

The module needs admin scope on api.tailscale.com to manage ACLs + federated identities. The credential is **operator-held only - never SSM, never any agent-readable store**. The tailnet ACL is the boundary that decides which machines an agent can SSH into, so its write credential must not be readable by the agents operating under that boundary. (It previously lived at `/tailscale/admin/oauth-client-{id,secret}` under `alias/admin-only`; that pattern is retired and the params are gone.)

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

`terraform/tailscale/`. Kai runs it (the env carries the admin pair, so this is a human-driven verb, not an agent one):

```
ward exec terraform-tailscale action=init
ward exec terraform-tailscale action=plan
ward exec terraform-tailscale action=apply
```

The wrapper validates that `TAILSCALE_API_KEY` (or the OAuth pair) is exported and hands the env to terraform. State at `s3://coilysiren-assets/terraform-state/infrastructure/tailscale.tfstate` (native lockfile, same shape as `terraform/grafana/`).

Adding a repo: append to `terraform.tfvars` `repos = [{ name = "<repo>" }, ...]` and re-apply.

## Host-side prereqs on kai-server

Not managed by this module, file follow-ups under #177:

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

## Subject tightening

Initial subject is the branch ref. Once an agent-driven trigger replaces the `push: main` trigger (dark-factory deploy from agent-opened PRs), switch `subject` in `main.tf` to `job_workflow_ref:coilysiren/<name>/.github/workflows/deploy.yml@refs/heads/main` so the token only validates from the named workflow file.

## Migration off the long-lived OAuth pair

Per repo:

1. Add to `repos` list, apply.
2. Workflow swaps `oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}` for the OIDC shape above.
3. After a green deploy, drop the `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` repo secrets.
4. When every consumer is migrated, retire `/tailscale/oauth-client-id` and `/tailscale/oath-secret` from SSM (`docs/k3s-deploy-notes.md` §6).

## See also

- [docs/k3s-deploy-notes.md](k3s-deploy-notes.md) - homelab topology, SSM inventory.
- [terraform/tailscale/README.md](../terraform/tailscale/README.md) - module shape and run instructions.
