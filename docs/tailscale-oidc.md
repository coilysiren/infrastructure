# Tailscale OIDC for CI deploys

Per-repo federated identities, no long-lived shared OAuth secret. Tracker: [coilysiren/infrastructure#177](https://github.com/coilysiren/infrastructure/issues/177).

## Why

Today every deployable repo carries the same `/tailscale/oauth-client-id` + `/tailscale/oath-secret` (typo) pair, synced to GH repo secrets. One leak grants `tag:ci` to every repo until manual rotation. Federated identity flips this: GitHub Actions mints a short-lived OIDC token, Tailscale verifies the subject claim, and only the matching `client_id` + `audience` ever sits in the repo. No long-lived bearer.

## Topology

- `tailscale_federated_identity` per repo, keyed by repo name. Subject `repo:coilysiren/<name>:ref:refs/heads/main`, scope `auth_keys`, tags `["tag:ci"]`.
- `github_actions_secret.TS_CLIENT_ID` and `TS_AUDIENCE` per repo.
- `tailscale_acl.main` carries the **full tailnet ACL** (groups, tagOwners, acls, ssh, nodeAttrs). The resource is a singleton in the Tailscale provider - applying it replaces the entire policy document. All tailnet edits go through this module; the admin console is read-only from here on.

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

## Admin OAuth client (one-time setup)

The module needs admin scope on api.tailscale.com to manage ACLs + federated identities. OAuth client over personal API key because the client itself never expires (only short-lived access tokens it mints, which the provider rotates transparently); API keys cap at 90 days.

1. Generate at <https://login.tailscale.com/admin/settings/trust-credentials> -> **Credential** -> **OAuth**. Scope `all:write`. Description "infrastructure terraform - tailscale-oidc module". Copy both halves immediately - the secret can't be retrieved after closing the dialog.
2. Apply `terraform/admin-kms/` first if it isn't already - that ships the `alias/admin-only` KMS key whose policy gates access at the resource layer (SSM itself has no resource policies). See `terraform/admin-kms/README.md`.
3. Stash in SSM under that key:
   ```
   coily ops aws ssm put-parameter \
     --name /tailscale/admin/oauth-client-id \
     --type SecureString --key-id alias/admin-only \
     --value FILL_ME_IN
   coily ops aws ssm put-parameter \
     --name /tailscale/admin/oauth-client-secret \
     --type SecureString --key-id alias/admin-only \
     --value FILL_ME_IN
   ```
4. Add both to the SSM inventory in `docs/k3s-deploy-notes.md` §6, noting they're under `alias/admin-only`.

Distinct from the runtime CI OAuth client at `/tailscale/oauth-*` (devices/auth_keys scope only) - that one stays narrow and continues backing `tailscale/github-action@v3` until each repo migrates to OIDC.

## Module

`terraform/tailscale-oidc/`. Run via:

```
coily exec terraform-tailscale-oidc action=init
coily exec terraform-tailscale-oidc action=plan
coily exec terraform-tailscale-oidc action=apply
```

The wrapper pulls `/tailscale/admin/oauth-client-id`, `/tailscale/admin/oauth-client-secret`, and `/github/pat` from SSM and exports them as `TAILSCALE_OAUTH_CLIENT_ID` + `TAILSCALE_OAUTH_CLIENT_SECRET` + `GITHUB_TOKEN`. State at `s3://coilysiren-assets/terraform-state/infrastructure/tailscale-oidc.tfstate` (native lockfile, same shape as `terraform/grafana/`).

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
- [terraform/tailscale-oidc/README.md](../terraform/tailscale-oidc/README.md) - module shape and run instructions.
