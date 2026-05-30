# Forgejo deploy plan

Drafted 2026-05-04. Revised 2026-05-05. Phase 1 executed 2026-05-05 (commits [`37c90b1`](https://github.com/coilyco-flight-deck/infrastructure/commit/37c90b1), [`b8fdd47`](https://github.com/coilyco-flight-deck/infrastructure/commit/b8fdd47), [`7b2512b`](https://github.com/coilyco-flight-deck/infrastructure/commit/7b2512b)). Phase 2 not yet executed.

`<HOME_PUBLIC_IP>` resolves from SSM `/coilysiren/home/public-ip`. See `k3s-deploy-notes.md`.

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

Four `coily aws ssm put-parameter --type SecureString` calls, all under `/forgejo/*`. Generate with `openssl rand` and pipe via `--value file:///dev/stdin` so the secret never lands in argv. Update `agentic-os-kai/SSM.md` (not `infrastructure/SSM.md` - that file does not exist; SSM inventory lives in agentic-os-kai) in the same logical change set, adding one bullet under the `/forgejo/*` prefix listing the four keys.

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

1. **Route 53 IP.** Plan asserted `<HOME_PUBLIC_IP>`. `dig +short eco.coilysiren.me` returns `<HOME_PUBLIC_IP>`. Confirmed.
2. **Route 53 write tooling.** No terraform manages the zone today (`infrastructure/terraform/` only has `grafana/`). Existing pattern is direct `aws` calls: `coily aws route53 change-resource-record-sets ...`.

## Apply order - phase 1 (tailnet-only)

1. Mint the 4 SSM params via the stdin pipe pattern. Verify with `coily aws ssm describe-parameters --filters Key=Name,Values=/forgejo/`.
2. Update `agentic-os-kai/SSM.md` with a `/forgejo/*` bullet listing the four keys. Commit + push (agentic-os-kai repo).
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

## Phase 1 retrospective (executed 2026-05-05)

Phase 1 completed end-to-end. Smoke passed: clone → push → re-clone → delete → `/metrics` (206 lines of Prometheus text). Three deviations from the original plan, captured here so phase 2 doesn't re-discover them:

1. **`FORGEJO__security__INSTALL_LOCK=true` is required** for the `forgejo` admin CLI to work. Without it the rootless image leaves `INSTALL_LOCK=false` in app.ini, and every CLI verb (`admin user create`, `doctor`, `dump`) bails with `MustInstalled() [F] Unable to load config file for an installed Forgejo instance`. With env-driven config the web installer is redundant; setting the lock skips it. Already in the manifest as of [`b8fdd47`](https://github.com/coilyco-flight-deck/infrastructure/commit/b8fdd47).

2. **`FORGEJO__session__COOKIE_SECURE=false` is required for the phase-1 tailnet-only window.** With `ROOT_URL=https://forgejo.coilysiren.me/` the default `[session] COOKIE_SECURE=auto` follows that scheme and marks session cookies Secure-only, so login over plain HTTP succeeds but the cookie gets dropped on the next request, breaking every authenticated flow. Already in the manifest as of [`7b2512b`](https://github.com/coilyco-flight-deck/infrastructure/commit/7b2512b), with a comment marking it as phase-1-only. **This env block must be removed in phase 2** (see step 3 below) - leaving it in once the public Ingress lands would weaken cookie security on the public surface.

3. **Tailnet HTTPS is not terminated by the ts-proxy on a default `tailscale.com/expose: "true"` Service.** The operator forwards plain HTTP at the Service port; encryption is provided at the WireGuard layer. The plan's phase-1 step 9 said "HTTPS git push" but the smoke ran over HTTP and is still real. Phase 2 ingress + cert-manager provides actual TLS termination at the public hostname. No manifest change needed for this one; just don't expect TLS on the tailnet URL.

`coily ssh kubectl` blocker mentioned in §"Apply path" turned out to be solvable: `k3s kubectl ...` directly via `ssh kai-server '...'` works without sudo because `/etc/rancher/k3s/k3s.yaml` is mode 644. Coily's wrapper added an unnecessary `sudo` prefix. Filed as [coily#56](https://github.com/coilyco-bridge/coily/issues/56). The `coily ops forgejo ...` verb group that would have removed the harness friction around `kubectl exec` is filed as [coily#57](https://github.com/coilyco-bridge/coily/issues/57).

The rotated admin password landed in SSM as `/forgejo/admin-password` (added 2026-05-05). The original plan said no admin-password in SSM; revised to keep it for password-manager retrieval since the rotated value is the actual long-lived credential, not the throwaway random one. Rotate manually via the UI then `coily aws ssm put-parameter --overwrite`.

## Apply order - phase 2 (public)

Only after phase-1 smoke passes (it has).

1. **Route 53 A record.** Add `forgejo.coilysiren.me → <HOME_PUBLIC_IP>` in zone `Z06714552N3MO04UBWF33`:

    ```sh
    coily --commit-scope=infrastructure aws route53 change-resource-record-sets \
      --hosted-zone-id Z06714552N3MO04UBWF33 \
      --change-batch '{
        "Changes": [{
          "Action": "CREATE",
          "ResourceRecordSet": {
            "Name": "forgejo.coilysiren.me.",
            "Type": "A",
            "TTL": 300,
            "ResourceRecords": [{"Value": "<HOME_PUBLIC_IP>"}]
          }
        }]
      }'
    ```

    Verify with `dig +short forgejo.coilysiren.me`. Should return `<HOME_PUBLIC_IP>` within ~5 minutes.

2. **Add the Ingress to the manifest** (item 9 in §"Manifest shape"). Append at the bottom of `infrastructure/deploy/forgejo.yml`:

    ```yaml
    ---
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: forgejo
      namespace: forgejo
      annotations:
        cert-manager.io/cluster-issuer: letsencrypt-production
        kubernetes.io/tls-acme: "true"
    spec:
      ingressClassName: traefik
      tls:
        - hosts:
            - forgejo.coilysiren.me
          secretName: forgejo-tls
      rules:
        - host: forgejo.coilysiren.me
          http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: forgejo
                    port:
                      number: 80
    ```

3. **Remove the phase-1-only `FORGEJO__session__COOKIE_SECURE` env block** from the Deployment (the one with the "Phase-1 only" comment). Leaving it in weakens cookie security on the public HTTPS surface, since `auto` will correctly mark cookies Secure-only once `ROOT_URL` resolves to a real HTTPS endpoint.

4. **Commit + push.** Single commit covers both edits (add Ingress, drop COOKIE_SECURE override). Suggested subject:

    > forgejo: phase-2 public Ingress (cert-manager DNS-01 + drop COOKIE_SECURE override)

5. **Pull + apply on kai-server:**

    ```sh
    coily --commit-scope=infrastructure ssh git pull /home/kai/projects/coilysiren/infrastructure
    ssh kai-server 'cd /home/kai/projects/coilysiren/infrastructure && k3s kubectl apply -f deploy/forgejo.yml'
    ```

    The Recreate strategy will roll the forgejo pod (cookie env drop forces a restart). Wait for ready:

    ```sh
    until [ "$(ssh kai-server 'k3s kubectl -n forgejo get pod -l app=forgejo -o jsonpath="{.items[0].status.containerStatuses[0].ready}"')" = "true" ]; do sleep 5; done
    ```

6. **Watch the certificate.** DNS-01 takes 1-2 min on first issuance:

    ```sh
    ssh kai-server 'k3s kubectl -n forgejo get certificate forgejo-tls -w'
    ```

    Wait for `READY=True`. If it stalls, check the Order: `k3s kubectl -n forgejo describe order` and `k3s kubectl -n forgejo describe challenge`. Most common failure mode here is the cert-manager service account missing the route53 perms; re-derive from the existing `eco.coilysiren.me` cert if so.

7. **Re-run the smoke against the public hostname.** Same shape as the phase-1 smoke loop, swap the tailnet URL for the public one:

    - Create a temporary `coilysiren/scratch` repo via the UI at `https://forgejo.coilysiren.me/`.
    - Clone over HTTPS using the per-call `GIT_ASKPASS` shape from phase 1, with credentials `coilysiren` / SSM `/forgejo/admin-password`.
    - Add a file, commit, push.
    - Re-clone fresh, diff matches.
    - Delete the repo via the UI (Settings → Delete Repository → typed-name confirm).
    - `curl https://forgejo.coilysiren.me/metrics` returns Prometheus text.

8. **Verify TLS chain explicitly:**

    ```sh
    curl -sI https://forgejo.coilysiren.me/ | head -3
    openssl s_client -connect forgejo.coilysiren.me:443 -servername forgejo.coilysiren.me </dev/null 2>/dev/null \
      | openssl x509 -noout -issuer -subject -dates
    ```

    Issuer should be Let's Encrypt R3/R10/R11 (whatever's current). `notAfter` ~90 days out.

9. **Verify session cookies are Secure-only over HTTPS** (sanity check that the COOKIE_SECURE drop took effect correctly):

    ```sh
    curl -sI https://forgejo.coilysiren.me/user/login | grep -i set-cookie
    ```

    The `i_like_gitea` (or similar) session cookie should carry `Secure; HttpOnly`.

10. **Schedule the post-push CI verification** per `infrastructure/AGENTS.md` (300s after push, re-check at +180s if in progress). Run `coily gh run list --limit 5` from the infra repo.

## Phase 2 rollback

If the cert never issues, or the public surface breaks in a way that can't be hot-fixed:

1. `k3s kubectl -n forgejo delete ingress forgejo` on kai-server.
2. Revert the manifest commit, push, re-apply.
3. The tailnet front door (`http://forgejo/`) keeps working throughout - nothing in phase 2 touches the tailnet Service or the ts-proxy.

The Route 53 record is safe to leave in place; without the Ingress it just resolves to a public IP that returns nothing on port 443.

## Followups (not blocking first deploy)

- **Backup CronJob**: weekly `forgejo dump` + `pg_dump`, writing to a sibling PVC. Drill restore before treating durable (eval note Watch-item #2).
- **Confirm RAM floor**: eval Watch-item #1. Run `coily ssh kubectl top pod -n forgejo` after a week of light use, retune limits.
- **Forgejo Actions runner**: separate decision. Skip on first deploy.
- **Federation (ActivityPub)**: experimental, skip.
- **`coily ssh kubectl` sudo path**: filed as [coily#56](https://github.com/coilyco-bridge/coily/issues/56). The wrapped command is `sudo k3s kubectl ...` but the kubeconfig at `/etc/rancher/k3s/k3s.yaml` is mode 644, so the sudo prefix is unnecessary. Fix is a one-line change in `ops_ssh.go`. Workaround in the meantime: plain `ssh kai-server 'k3s kubectl ...'` works fine.
- **`coily ops forgejo` verb group**: filed as [coily#57](https://github.com/coilyco-bridge/coily/issues/57). Wraps the in-pod `forgejo` CLI (admin user create/list/change-password, doctor, dump, regenerate hooks/keys, actions generate-runner-token) so future admin work doesn't need to wave through harness deny-rules on `kubectl exec`. Depends on #56.

## Traps to remember (from k3s-deploy-notes.md)

- `hostAliases` for `eco.coilysiren.me` → `192.168.0.194` if Forgejo ever calls back into the cluster.
- DNS-01 cert will take 1-2 min on first issuance.
- StatefulSet `serviceName` must match the headless Service name or pods won't get DNS.
- Rootless image first-boot does a recursive chown on the PVC. 60s liveness delay covers it.
- No GHCR pull-secret needed, image is on `codeberg.org` which serves public OCI artifacts unauth.
- `K8S_SERVER` for any CI must be the tailnet IP literal, not `kai-server` (MagicDNS doesn't resolve from GitHub runners). See k3s-deploy-notes §"K8S_SERVER".
