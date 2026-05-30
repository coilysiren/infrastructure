# repo-recall on kai-server (k3s, tailnet-only)

Sibling to [`k3s-deploy-notes.md`](k3s-deploy-notes.md) and
[`forgejo-deploy-plan.md`](forgejo-deploy-plan.md). repo-recall runs in
k3s as a two-container Pod fronted by the tailscale operator. No public
DNS, no Ingress, no Route 53. MagicDNS hostname:
`repo-recall.<tailnet>.ts.net`.

## Shape

- **Manifest**: [`deploy/repo-recall.yml`](../deploy/repo-recall.yml).
  One Deployment, one Pod, two containers (`api` + `web`), one Service
  with `tailscale.com/expose: "true"` + `tailscale.com/hostname:
  repo-recall`. Same pattern as forgejo.
- **Images**: `ghcr.io/coilysiren/repo-recall-{api,web}:latest`.
  Pushed by [`.github/workflows/docker.yml`](https://github.com/coilyco-flight-deck/repo-recall/blob/main/.github/workflows/docker.yml)
  in coilysiren/repo-recall on every push to `main` (and on tags).
  Images are public, no `imagePullSecret`.
- **Traffic**:
  `tailnet peer → ts-proxy (repo-recall.<tailnet>.ts.net:443)
   → Service:80 → web container :8080 → (path-matched) → api container :7777`.
  Caddy in the `web` container reverse-proxies `/api/*`,
  `/openapi.json`, `/mcp(/*)` to the API sidecar at `localhost:7777`.
- **No PVC**: redb cache is wipe-on-restart by design (no migrations),
  tantivy index is the same shape. `emptyDir` is sufficient.
- **No secrets**: repo-recall has no DB, no app password, no DSN.

## Pre-reqs

1. **Tailscale operator** already running in the cluster (forgejo
   proves it).
2. **GHCR images published** by coilysiren/repo-recall's `docker.yml`
   workflow. First push to `main` after the workflow lands creates
   them; verify with
   `coily ops gh api /users/coilysiren/packages/container/repo-recall-api/versions`.
3. **Old systemd path retired** on kai-server before applying (see
   below) so the `tailscale serve --https=443` registration is freed
   and the brew-installed daemon stops fighting the new path for
   port 7777 (only matters if a hostNetwork-style path is later
   added; today the k3s Pod is on the CNI so no collision).

## First-time setup on kai-server

```sh
# 1. Retire the host systemd path. Doing this first releases the
#    tailscale serve registration on kai-server.<tailnet>.ts.net:443.
sudo systemctl disable --now repo-recall.service \
                              repo-recall-update.service \
                              repo-recall-update.timer
sudo rm -f /etc/systemd/system/repo-recall.service \
           /etc/systemd/system/repo-recall-update.service \
           /etc/systemd/system/repo-recall-update.timer
sudo systemctl daemon-reload
tailscale serve --https=443 off
brew uninstall repo-recall   # optional - frees the binary

# 2. Apply the k3s manifest.
sudo k3s kubectl apply -f deploy/repo-recall.yml

# 3. Watch the ts-proxy come up.
sudo k3s kubectl -n repo-recall get pods,svc -w
sudo k3s kubectl -n tailscale get pods | grep repo-recall

# 4. Verify from a tailnet peer (laptop / phone).
curl -sf https://repo-recall.<tailnet>.ts.net/healthz
curl -sf https://repo-recall.<tailnet>.ts.net/api/scan-version
```

The exact `<tailnet>` suffix comes from `tailscale status` on any node.

## Auth model

Tailnet membership IS the auth. The Service is `ClusterIP` and the
`tailscale.com/expose` annotation tells the operator to stand up a
ts-proxy reachable only from tailnet peers. No app-level login. If
the tailnet ever gains a device that shouldn't see session metadata,
gate on the `Tailscale-User-Login` header the proxy injects.

## Upgrades

Images are tagged `latest` on every push to `main`. Roll a deploy with:

```sh
sudo k3s kubectl -n repo-recall rollout restart deployment/repo-recall
sudo k3s kubectl -n repo-recall rollout status  deployment/repo-recall
```

`imagePullPolicy: Always` ensures the rollout pulls the fresh
`:latest` digest. There is no longer a brew-upgrade + try-restart loop.

## Known gaps

- **Filesystem access is not wired.** The host project tree
  (`/home/kai/projects/coilysiren`) and the Claude session JSONL
  (`/home/kai/.claude/projects/*.jsonl`) are not mounted into the API
  container. Without them the dashboard renders empty. The host
  systemd unit had unrestricted host access; the k3s replacement
  needs an explicit `hostPath` mount or a local-path PVC populated by
  a sidecar - decision pending in a follow-up to
  coilyco-flight-deck/infrastructure#176.
- **`gh` is not authenticated** inside the API container. The runtime
  layer carries `gh` so the ingest can shell out, but
  `GH_TOKEN`/`gh auth login` plumbing also lands in the
  filesystem-access follow-up.

## Troubleshooting

- **`repo-recall.<tailnet>.ts.net` doesn't resolve** → the ts-proxy
  StatefulSet hasn't come up. Check
  `sudo k3s kubectl -n tailscale get pods,statefulsets`. If it's stuck
  pulling, the operator's OAuth credentials may have expired.
- **Pod is `CrashLoopBackOff` on `api`** → `kubectl logs` it. Most
  common cause: `REPO_RECALL_CWD` resolves to an empty path (expected
  until the filesystem mount lands; the container should still come up
  with an empty index). If the binary panics at start, that's a real
  bug.
- **Caddy 502s on `/api`** → the API container isn't listening yet, or
  is bound to `0.0.0.0` instead of `127.0.0.1`. The deploy pins
  `REPO_RECALL_HOST=127.0.0.1` since same-Pod loopback is sufficient.
