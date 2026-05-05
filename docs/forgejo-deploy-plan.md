# Forgejo deploy plan

Drafted 2026-05-04. Revised 2026-05-05. Not yet executed.

Background: [`coilyco-vault/Obsidian Vault/Notes/forgejo-evaluation.md`](../../coilyco-vault/Obsidian%20Vault/Notes/forgejo-evaluation.md). General homelab pattern: [`k3s-deploy-notes.md`](k3s-deploy-notes.md).

## Decisions locked in

| Choice | Value |
|---|---|
| Hostname (phase 2) | `forgejo.coilysiren.me` |
| Phase 1 reachability | tailnet only, MagicDNS via `tailscale.com/expose: "true"` on the Service. No Ingress, no Route 53. |
| Container image | `codeberg.org/forgejo/forgejo:15.0.1-rootless` |
| Database | Postgres 17 sidecar (StatefulSet, separate PVC) |
| Forgejo PVC | 20 GiB, `local-path` storageClass |
| Postgres PVC | 5 GiB, `local-path` |
| SSH (port 2222) | Disabled. HTTPS-only git. |
| SMTP | Disabled. |
| Registration | Closed. Admin invites only. |
| Manifest location | `infrastructure/deploy/forgejo.yml` (single file, all docs) |
| Disk headroom | 318 GB free of 480 GB on `/`. 25 GiB total ask is ~8% of free. |
| Admin password handling | `forgejo admin user create --random-password`, captured once from pod stdout, rotated by Kai in the browser immediately. **Not stored in SSM.** |

## Two-phase rollout

**Phase 1: tailnet-only smoke.** Apply the manifest minus the Ingress. Service keeps `tailscale.com/expose: "true"` so the tailscale operator stands up a ts-proxy and gives the Service a MagicDNS name (something like `forgejo-<tailnet>.ts.net`, exact name surfaces in the operator's logs / the ts-proxy StatefulSet CR after apply). Smoke-test over tailnet only.

**Phase 2: public.** Once tailnet smoke passes (HTTPS git push + clone + delete loop), add the Route 53 A record and the Ingress.

This keeps Route 53 + cert-manager DNS-01 + public ingress off the table until forgejo is proven to work end-to-end inside the trust boundary.

## SSM secrets to mint (4, not 5)

Four `coily aws ssm put-parameter --type SecureString` calls, all under `/forgejo/*`. Generate with `openssl rand` and pipe via `--value file:///dev/stdin` so the secret never lands in argv. Update `coilyco-ai/SSM.md` (not `infrastructure/SSM.md` - that file does not exist; SSM inventory lives in coilyco-ai) in the same logical change set, adding one bullet under the `/forgejo/*` prefix listing the four keys.

| SSM path | Length / format | Forgejo env binding |
|---|---|---|
| `/forgejo/secret-key` | 64 char hex (`openssl rand -hex 32`) | `FORGEJO__security__SECRET_KEY` |
| `/forgejo/internal-token` | 105 char (`openssl rand -base64 78` then strip `=`/newlines) | `FORGEJO__security__INTERNAL_TOKEN` |
| `/forgejo/lfs-jwt-secret` | 43 char base64url (`openssl rand -base64 32` → tr) | `FORGEJO__server__LFS_JWT_SECRET` |
| `/forgejo/db-password` | 32 char alnum (`openssl rand -base64 24` → tr) | `FORGEJO__database__PASSWD` + Postgres `POSTGRES_PASSWORD` |

Canonical write shape (no value in argv):

```sh
openssl rand -hex 32 \
  | coily --commit-scope=infrastructure aws ssm put-parameter \
      --name /forgejo/secret-key \
      --type SecureString \
      --value file:///dev/stdin
```

The `--value file://` prefix is a built-in aws-CLI feature; coily is a pass-through and inherits it. `/dev/stdin` is fd 0 of the aws process, fed by the pipe.

**No `/forgejo/admin-password` param.** Forgejo's CLI generates the initial password inside the pod (see "Apply order" below); Kai logs in once and rotates to her own value. Storing the generated password in SSM only to retrieve it 30 seconds later is paper over the same exposure surface.

## Manifest shape (`infrastructure/deploy/forgejo.yml`)

Doc order matters. Single static file (no envsubst, image is version-pinned).

1. **Namespace** `forgejo`
2. **ExternalSecret** `forgejo-secrets` (one resource, four keys: `secret-key`, `internal-token`, `lfs-jwt-secret`, `db-password`). Uses existing `aws-parameter-store` ClusterSecretStore (kind: `ClusterSecretStore`, defined in `infrastructure/deploy/secretstore.yml`).
3. **PersistentVolumeClaim** `forgejo-data`, 20 GiB, RWO, `local-path`. Mounts at `/var/lib/gitea`.
4. **PersistentVolumeClaim** `forgejo-db-data`, 5 GiB, RWO, `local-path`. Mounts at `/var/lib/postgresql/data`.
5. **StatefulSet** `forgejo-db`
    - `postgres:17` (official)
    - `replicas: 1`, `serviceName: forgejo-db`
    - Env: `POSTGRES_DB=forgejo`, `POSTGRES_USER=forgejo`, `POSTGRES_PASSWORD` from `forgejo-secrets/db-password`, `PGDATA=/var/lib/postgresql/data/pgdata`
    - Resources: requests `100m / 256Mi`, limits `500m / 768Mi`
    - Mount `forgejo-db-data` at `/var/lib/postgresql/data`
    - Probes: `pg_isready -U forgejo` for both readiness and liveness
6. **Service** `forgejo-db` ClusterIP, port 5432, selector matches the StatefulSet
7. **Deployment** `forgejo`
    - `image: codeberg.org/forgejo/forgejo:15.0.1-rootless`
    - `replicas: 1`, `strategy: { type: Recreate }` (RWO PVC, can't roll)
    - `securityContext` at pod level: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000` (so the rootless image can write to the PVC)
    - Resources: requests `200m / 512Mi`, limits `1000m / 1500Mi`
    - Env via `secretKeyRef` to `forgejo-secrets`:
        - `FORGEJO__security__SECRET_KEY`
        - `FORGEJO__security__INTERNAL_TOKEN`
        - `FORGEJO__server__LFS_JWT_SECRET`
        - `FORGEJO__database__PASSWD`
    - Static env:
        - `FORGEJO__database__DB_TYPE=postgres`
        - `FORGEJO__database__HOST=forgejo-db:5432`
        - `FORGEJO__database__NAME=forgejo`
        - `FORGEJO__database__USER=forgejo`
        - `FORGEJO__database__SSL_MODE=disable` (in-cluster)
        - `FORGEJO__server__DOMAIN=forgejo.coilysiren.me`
        - `FORGEJO__server__ROOT_URL=https://forgejo.coilysiren.me/`
        - `FORGEJO__server__HTTP_PORT=3000`
        - `FORGEJO__server__DISABLE_SSH=true`
        - `FORGEJO__service__DISABLE_REGISTRATION=true`
        - `FORGEJO__metrics__ENABLED=true`
        - `FORGEJO__mailer__ENABLED=false`
        - `FORGEJO__server__LFS_START_SERVER=true`
    - Port 3000
    - Readiness + liveness on `GET /api/healthz`, port 3000. Liveness `initialDelaySeconds: 60` (rootless first-boot does chown).
    - Volume `forgejo-data` mounted at `/var/lib/gitea`
    - `hostAliases` pinning `eco.coilysiren.me` (and any other `*.coilysiren.me` Forgejo might call) to `192.168.0.194` per deploy notes §10
    - `imagePullSecrets`: none (codeberg.org packages are public, no GHCR pull-secret needed)
8. **Service** `forgejo` ClusterIP, port 80 → 3000, annotations `tailscale.com/expose: "true"` and `tailscale.com/hostname: forgejo` (the second pins the MagicDNS name; without it the operator picks one. URL becomes `https://forgejo.<tailnet>.ts.net/` deterministically.)
9. **Ingress** `forgejo` - **Phase 2 only.** Held back from the initial manifest. ingressClassName `traefik`, annotations `cert-manager.io/cluster-issuer: letsencrypt-production` + `kubernetes.io/tls-acme: "true"`, host `forgejo.coilysiren.me`, TLS secret `forgejo-tls`.

## Apply path

**Pattern: commit local → push to GitHub → SSH to kai-server → `git pull` → `sudo k3s kubectl apply`.** This is Kai's conventional homelab deploy flow for the infrastructure repo. No CI-driven apply (infra CI stays pylint-only by decision). No `coily ssh deploy <target>` verb needed.

Watching from this Mac is best-effort. As of 2026-05-05:
- `coily kubectl` on this Mac fails (`localhost:8080: connection refused`, no local kubeconfig). Expected.
- `coily ssh kubectl get nodes` fails with `sudo: a password is required` because the wrapped command is `sudo k3s kubectl ...` and NOPASSWD isn't configured for this path. So `kubectl -w` watching from Mac is currently unavailable.
- Workarounds for watching: open an interactive SSH session to kai-server and run `sudo k3s kubectl ...` there, or fix the sudo path in coily as a separate issue. Not blocking for first deploy.

Tailscale on this Mac is up (verified 2026-05-05).

## Phase-2 prerequisites (deferred until phase-1 smoke passes)

1. **Route 53 IP.** Plan asserted `99.110.50.213`. `dig +short eco.coilysiren.me` returns `99.110.50.213`. Confirmed.
2. **Route 53 write tooling.** No terraform manages the zone today (`infrastructure/terraform/` only has `grafana/`). Existing pattern is direct `aws` calls: `coily aws route53 change-resource-record-sets ...`.

## Apply order - phase 1 (tailnet-only)

1. Mint the 4 SSM params via the stdin pipe pattern. Verify with `coily aws ssm describe-parameters --filters Key=Name,Values=/forgejo/`.
2. Update `coilyco-ai/SSM.md` with a `/forgejo/*` bullet listing the four keys. Commit + push (coilyco-ai repo).
3. Write `infrastructure/deploy/forgejo.yml` per shape above, **omitting the Ingress (item 9)**. Commit + push (infrastructure repo).
4. SSH to kai-server. `cd` into the infrastructure clone there, `git pull`, then:

    ```sh
    sudo k3s kubectl apply -f deploy/forgejo.yml
    ```

5. Watch from the same SSH session: `sudo k3s kubectl -n forgejo get pods,externalsecret -w`. Wait for `forgejo-db-0` Ready, then `forgejo-*` Ready. ExternalSecret should report `SecretSynced=True` within ~30s.
6. Find the tailnet MagicDNS name. The tailscale operator stands up a ts-proxy StatefulSet for the exposed Service; the assigned MagicDNS name surfaces in:
    - `sudo k3s kubectl -n tailscale get svc` (on kai-server)
    - `tailscale status` from this Mac
7. Create admin user with a random password generated inside the pod:

    ```sh
    sudo k3s kubectl -n forgejo exec deploy/forgejo -- \
      forgejo admin user create \
        --username coilysiren \
        --email coilysiren@gmail.com \
        --admin \
        --random-password
    ```

    Forgejo prints the generated password to stdout (call it `$INITIAL`). Capture it for use in step 8 only.

8. **Browser automation via playwright-mcp.** Drive the post-init flow with `mcp__playwright__*` tools, no HITL:
    - Navigate to `https://forgejo.<tailnet>.ts.net/user/login`, log in as `coilysiren` / `$INITIAL`.
    - Settings → Account → Change Password. Generate `$ROTATED = openssl rand -base64 24`, fill old/new, submit.
    - Repositories → New, create `coilysiren/scratch` (public, default branch `main`), submit.
    - Print `$ROTATED` to chat once at the end of the smoke; Kai files it in her password manager. Do not write either password to disk.

   *Setup confirmed 2026-05-05: `playwright-mcp` registered at user scope (`claude mcp add -s user playwright -- npx -y @playwright/mcp@latest`), `playwright` CLI v1.59.1 installed globally, Chromium cached at `~/Library/Caches/ms-playwright/`. `claude mcp list` shows the server connected. Tools surface as `mcp__playwright__*` and were end-to-end smoke-tested in-session 2026-05-05 against `the-internet.herokuapp.com/login`: navigate + snapshot + fill_form + click all returned cleanly and the post-login redirect was observed. The four primitives step 8 needs are working. HITL fallback (hand `$INITIAL` to Kai in chat, she rotates + creates `scratch` herself) only applies if `mcp__playwright__*` is unexpectedly absent at session start.*

   Ref-handle caveat: snapshot refs (`ref=eN`) are page-scoped. After every navigation (login → settings, settings → repos/new, etc.) re-call `browser_snapshot` before the next `fill_form`/`click`. Don't reuse refs across navigations.

9. **End-to-end smoke** (must pass before phase 2). Driven from this Mac after step 8:
    - Clone `https://forgejo.<tailnet>.ts.net/coilysiren/scratch.git` using a temporary credential helper / per-call `GIT_ASKPASS` so the password never lands in shell history or a persistent remote URL.
    - Add a file, commit, `git push` (HTTPS only, SSH disabled). Confirm push succeeds.
    - Re-clone fresh into a tmpdir, confirm content matches.
    - Browser-automate repo deletion via playwright-mcp (Settings → Delete Repository → confirm typed name). Falls back to HITL if mcp tools aren't available.
    - `curl https://forgejo.<tailnet>.ts.net/metrics` returns Prometheus text.

10. Schedule the post-push CI check on the infrastructure push per `infrastructure/AGENTS.md`. (CI is pylint-only, but the post-push verify rule still applies.)

## Apply order - phase 2 (public)

Only after phase-1 smoke passes.

1. Add the Route 53 A record `forgejo.coilysiren.me → 99.110.50.213` in zone `Z06714552N3MO04UBWF33` via `coily aws route53 change-resource-record-sets`.
2. Add the Ingress (manifest item 9) to `infrastructure/deploy/forgejo.yml`. Commit + push.
3. SSH to kai-server, `git pull`, `sudo k3s kubectl apply -f deploy/forgejo.yml`.
4. Watch certificate (on kai-server): `sudo k3s kubectl -n forgejo get certificate forgejo-tls -w`. DNS-01 takes 1-2 min on first issuance.
5. Re-run the phase-1 smoke against `https://forgejo.coilysiren.me/` (replace tailnet URL).

## Followups (not blocking first deploy)

- **Backup CronJob**: weekly `forgejo dump` + `pg_dump`, writing to a sibling PVC. Drill restore before treating durable (eval note Watch-item #2).
- **Confirm RAM floor**: eval Watch-item #1. Run `coily ssh kubectl top pod -n forgejo` after a week of light use, retune limits.
- **Forgejo Actions runner**: separate decision. Skip on first deploy.
- **Federation (ActivityPub)**: experimental, skip.
- **`coily ssh kubectl` sudo path**: currently fails with `sudo: a password is required`. Wrapped command is `sudo k3s kubectl ...`. Either configure NOPASSWD for k3s on kai-server or change the wrapper to read sudo password from SSM. Track as a coily issue. Not blocking the deploy (kai-server SSH session works fine), but blocks ergonomic Mac-side watching.

## Traps to remember (from k3s-deploy-notes.md)

- `hostAliases` for `eco.coilysiren.me` → `192.168.0.194` if Forgejo ever calls back into the cluster.
- DNS-01 cert will take 1-2 min on first issuance.
- StatefulSet `serviceName` must match the headless Service name or pods won't get DNS.
- Rootless image first-boot does a recursive chown on the PVC. 60s liveness delay covers it.
- No GHCR pull-secret needed, image is on `codeberg.org` which serves public OCI artifacts unauth.
- `K8S_SERVER` for any CI must be the tailnet IP literal, not `kai-server` (MagicDNS doesn't resolve from GitHub runners). See k3s-deploy-notes §"K8S_SERVER".
