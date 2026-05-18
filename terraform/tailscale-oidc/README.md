# terraform/tailscale-oidc

Per-repo Tailscale OIDC federated identities for GitHub Actions deploys to `tag:homelab`. Replaces the long-lived `/tailscale/oauth-client-id` + `/tailscale/oath-secret` pair that every deployable repo currently syncs to GH secrets.

## Shape

- `tailscale_federated_identity.ci` - `for_each` over the repo list loaded from `repos.yaml`. One identity per repo, subject pinned to `repo:coilysiren/<name>:ref:refs/heads/<branch>`, tags `["tag:ci"]`, scope `auth_keys`.
- `github_actions_secret.ts_client_id` / `github_actions_secret.ts_audience` - per-repo `TS_CLIENT_ID` and `TS_AUDIENCE` consumed by `tailscale/github-action@v4`.
- `tailscale_acl.main` - **full tailnet ACL document**. Singleton resource; replaces the entire policy at <https://login.tailscale.com/admin/acls> on apply. All tailnet policy lives in `main.tf` from here on - hand-edits in the console get overwritten next apply.

## Auth

`scripts/k8s.py terraform-tailscale-oidc` pulls from SSM and exports:

- `TAILSCALE_OAUTH_CLIENT_ID` <- `/tailscale/admin/oauth-client-id`
- `TAILSCALE_OAUTH_CLIENT_SECRET` <- `/tailscale/admin/oauth-client-secret`
- `GITHUB_TOKEN` <- `/github/pat`

Admin OAuth client (scope `all:write`) generated at <https://login.tailscale.com/admin/settings/trust-credentials>.

See [`docs/tailscale-oidc.md`](../../docs/tailscale-oidc.md) for the one-time SSM stash.

## Run

```
coily exec terraform-tailscale-oidc action=init
coily exec terraform-tailscale-oidc action=plan
coily exec terraform-tailscale-oidc action=apply
```

## Adding a repo

Append to `repos.yaml`:

```yaml
repos:
  - coilysiren/backend
  - coilysiren/new-deployable-repo
```

Branch is hardcoded to `main` in `main.tf`.

Then `coily exec terraform-tailscale-oidc action=apply`. The repo's GH Actions workflow can then use:

```yaml
- uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_CLIENT_ID }}
    audience: ${{ secrets.TS_AUDIENCE }}
    tags: tag:ci
    use-cache: 'true'
```

Subject is `repo:coilysiren/<name>:ref:refs/heads/main` by default. Tighten to `job_workflow_ref:coilysiren/<name>/.github/workflows/deploy.yml@refs/heads/main` by switching `subject` in `main.tf` once dark-factory agents start opening PRs against deployable repos.

## Host-side prereqs (kai-server)

Not managed by this module - file under [coilysiren/infrastructure#177](https://github.com/coilysiren/infrastructure/issues/177) follow-ups:

- `sudo tailscale set --ssh`
- `deploy` user + `/etc/sudoers.d/deploy-k3s`
- Tailscale SSH check-mode set so federated identity bearer tokens satisfy the SSH `accept` rule

See `docs/tailscale-oidc.md`.
