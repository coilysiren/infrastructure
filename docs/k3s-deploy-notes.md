# Homelab k3s + Tailscale deploy — the whole story

> **Placeholders.** `<HOME_PUBLIC_IP>` resolves from SSM `/coilysiren/home/public-ip` (or `dig +short eco.coilysiren.me`). `<KAI_SERVER_TAILNET_IP>` resolves from SSM `/coilysiren/kai-server/tailnet-ip` (or `tailscale ip -4 kai-server`). Literals are kept out of this public repo to avoid geo-locating the home cluster.

Single source of truth for how services get from a GitHub push to
`*.coilysiren.me` on the k3s cluster running on `kai-server`. Every
non-obvious decision has a scar behind it — this doc exists because
we've hit a different flavour of the same-looking deploy mess four
times across four repos.

Authoritative reference stack (what works today):
[coilysiren/backend](https://github.com/coilysiren/backend) set the
shape; [coilysiren/eco-jobs-tracker](https://github.com/coilysiren/eco-jobs-tracker)
is the cleanest modern instance (see `49f99e4 CI: revert to
backend-shape direct kubectl deploy`);
[coilysiren/eco-mcp-app](https://github.com/coilysiren/eco-mcp-app)
adds the declarative GHCR pull-secret pattern;
[coilysiren/galaxy-gen](https://github.com/coilysiren/galaxy-gen)
`bddec18 workflow: match eco-spec-tracker byte-for-byte` codifies that
alignment.

When things are broken, start at §9 (triage tree). When setting up a
new repo, start at §8 (checklist). The sections between are reference
material that §8 and §9 cite.

---

## 1. Homelab topology

- **kai-server**: single-node k3s cluster, Ubuntu 22.04, kernel 6.8,
  18-core, 32 GiB RAM, 480 GB NVMe. Also a GNOME desktop with xrdp
  (:3389) and game servers (Eco, Factorio, Icarus, Core Keeper) via
  systemd.
- **Tailscale node `kai-server`** at `<KAI_SERVER_TAILNET_IP>` (this is the
  tailnet IPv4).
- **LAN IP**: `192.168.0.194`.
- **Public IP**: `<HOME_PUBLIC_IP>` (home residential, NAT'd to the LAN
  IP).
- **Traefik LoadBalancer** listens on `192.168.0.194:80/443` in
  namespace `kube-system`.
- **Public ingress path**: public DNS → public IP → home router NAT →
  `192.168.0.194` → traefik → Ingress → Service → pod.
- **Tailnet ingress path**: peer → tailnet IP `<KAI_SERVER_TAILNET_IP>` → k3s
  API `:6443` (how CI deploys), OR tailscale-operator ts-proxy
  StatefulSet per-Service (for `tailscale.com/expose: "true"`
  services).
- **Cluster namespaces** we run in: `kube-system` (traefik, coredns,
  metrics-server, local-path-provisioner, svclb), `cert-manager`,
  `external-secrets`, `tailscale`, `coilysiren-backend`,
  `coilysiren-eco-mcp-app`, `coilysiren-eco-spec-tracker`,
  `coilysiren-galaxy-gen`.
- **Host-side systemd services on kai-server**: `k3s.service`,
  `eco-server.service`, `factorio-server.service`,
  `icarus-server.service`, `core-keeper-server.service`. Scripts in
  `infrastructure/scripts/`, units in `infrastructure/systemd/`.
- **Eco game server** (the game the eco-* app repos talk to) is
  reachable inside the LAN at `http://eco.coilysiren.me:3001/info`.
  Pods in k3s reach it via `hostAliases` pinning it to the LAN IP.
- **DNS**: `coilysiren.me` is an **AWS Route 53** hosted zone, id
  `Z06714552N3MO04UBWF33`.
- **Service A records** (all point at `<HOME_PUBLIC_IP>`):
  `api`, `eco-mcp`, `eco-jobs-tracker`, `eco`, `galaxy-gen`.
- **Host-side Caddy** runs natively on kai-server. Two roles, both
  tailnet-internal, neither affecting the public Traefik path:
  - `:8082` serves `/var/lib/coily/dashboard.html` (the audit dashboard
    regenerated every 5 min by `coily-audit-dashboard.timer`).
  - `http://kai-server { import sites/*.caddy }` aggregates tailnet
    shortcuts to cluster services. Each shortcut is a `handle_path`
    block generated from a sibling repo's `config.yml`
    `tailnet.shortcut` field. Generator:
    `scripts/generate-caddy-shortcuts.py`. Workflow:
    `.github/workflows/caddy-shortcuts.yml` (daily cron + dispatch).
    Reload on kai-server is manual today: `git pull` then
    `sudo caddy reload --config /etc/caddy/Caddyfile`.

## 2. SSM parameter inventory

Every secret of lasting value lives in **AWS SSM Parameter Store**,
not in Kubernetes directly. Cluster-side access is via the
**external-secrets** operator and its `aws-parameter-store`
`ClusterSecretStore`. CI-side access is via `aws ssm get-parameter`
from shell steps.

- **`/github/pat`** — GitHub PAT with `read:packages` for
  `ghcr.io/coilysiren`. In active use.
  - External-secrets synthesizes a
    `docker-registry`-typed-as-`dockerconfigjson` Secret from it in
    each deploying namespace (see §5 ExternalSecret block).
  - The `deploy-secrets-docker-repo` Makefile target reads it via
    `aws ssm get-parameter` for manual bootstrap when external-secrets
    isn't handling a namespace.
- **`/tailscale/oauth-client-id`** — IN USE. OAuth client ID for the
  `tailscale/github-action@v3` in CI. Sync to GH secret
  `TS_OAUTH_CLIENT_ID`.
- **`/tailscale/oath-secret`** — IN USE. **Typo preserved** — the key
  says "oath" not "oauth". Sync to GH secret `TS_OAUTH_SECRET`. The
  typo is load-bearing: fixing it would break the working path,
  because the correctly-spelled `/tailscale/oauth-secret` doesn't
  exist.
- **`/tailscale/k3s/oauth-client-id`** — **ORPHANED. Do not use.**
  This OAuth client has a tighter ACL that doesn't grant the `tag:ci`
  machine the access it needs to reach `<KAI_SERVER_TAILNET_IP>:6443`. Named
  like it's k3s-specific; in reality it's the opposite — the
  `/k3s/` scoping restricts it.
- **`/tailscale/k3s/oath-secret`** — ORPHANED. Same reason.
- **K3s kubeconfig material is NOT in SSM.** The four `K8S_*` GitHub
  secrets are populated directly from `/home/kai/.kube/config` on
  kai-server via `yq` piped into `gh secret set`. This is why the
  `/k3s/*` SSM namespace is mostly empty.
- **`/coilysiren/home/public-ip`** — home residential public IP. Used in docs as `<HOME_PUBLIC_IP>` so the literal stays out of this public repo. Refresh if the ISP rotates.
- **`/coilysiren/kai-server/tailnet-ip`** — tailnet IPv4 for `kai-server`. Used in docs as `<KAI_SERVER_TAILNET_IP>`. Resolve at runtime via `tailscale ip -4 kai-server` when on the tailnet.
- **`/discord/channel/bots`** and friends — orthogonal; used by the
  Discord bot, not by web deploys.

## 3. GitHub repo secrets — canonical names and values

Every deployable repo needs the same six secrets. Set them with
`gh secret set ... --repo coilysiren/<repo>`.

### `K8S_SERVER` — must be the tailnet IP literal

**Value**: `https://<KAI_SERVER_TAILNET_IP>:6443`.

Not `https://kai-server:6443` (MagicDNS doesn't resolve inside GitHub
Actions runners even with `--accept-dns`). Not `https://192.168.0.194:6443`
(LAN IP unreachable from the internet, which is where the runner
lives). Not `https://<HOME_PUBLIC_IP>:6443` (public IP isn't in the
cert's SAN list).

The k3s-issued server cert has SANs for: `<KAI_SERVER_TAILNET_IP>` (tailnet),
`kai-server` (hostname), `127.0.0.1` (localhost), `192.168.0.194`
(LAN). Pick the one you can actually reach — from CI, that's the
tailnet IP.

Galaxy-gen spent three commits solving a problem created by storing
`kai-server` here. See `1189234 deploy: revert DNS-resolution dance;
secret now holds tailnet IP`.

### `K8S_CA_DATA`, `K8S_CLIENT_CERT_DATA`, `K8S_CLIENT_KEY_DATA`

Pipe field-by-field from kai-server's kubeconfig:

```bash
# Run on kai-server (or via tailscale ssh from your laptop):
yq '.clusters[0].cluster."certificate-authority-data"' /home/kai/.kube/config \
  | gh secret set K8S_CA_DATA --repo coilysiren/<repo>
yq '.users[0].user."client-certificate-data"' /home/kai/.kube/config \
  | gh secret set K8S_CLIENT_CERT_DATA --repo coilysiren/<repo>
yq '.users[0].user."client-key-data"' /home/kai/.kube/config \
  | gh secret set K8S_CLIENT_KEY_DATA --repo coilysiren/<repo>
```

Rotate all three together when the k3s client cert expires (default
is ~1 year). We hit the Apr 13 2026 expiry once; everyone's
`Unauthorized` errors got resolved by re-syncing these three in one
pass.

### `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`

Sync from the **non-`/k3s/`** SSM paths:

```bash
aws ssm get-parameter --name /tailscale/oauth-client-id \
  --with-decryption --query Parameter.Value --output text \
  | gh secret set TS_OAUTH_CLIENT_ID --repo coilysiren/<repo>
aws ssm get-parameter --name /tailscale/oath-secret \
  --with-decryption --query Parameter.Value --output text \
  | gh secret set TS_OAUTH_SECRET --repo coilysiren/<repo>
```

Pipe-through means the value never lands on disk or in the shell
history. **Do not run `aws ssm get-parameter ...` alone** — the
decrypted value prints to stdout and ends up in the transcript.

## 4. Canonical GitHub Actions workflow shape

Authoritative: `eco-jobs-tracker/.github/workflows/build-and-publish.yml`
after `49f99e4 CI: revert to backend-shape direct kubectl deploy`. The
SSH-pipe path was tried and abandoned; the tailnet IP direct-kubectl
path is what works today.

Three jobs: `test` → `build-publish` → `deploy`.

### `test` (language-specific)

eco-jobs-tracker uses `astral-sh/setup-uv@v5` + `uv run pytest` /
`ruff check` / `ruff format --check` / `mypy`. galaxy-gen uses
`actions/setup-node@v4` + Playwright. Backend has no `test` job
(migrated to uv in `2dc5a85` but the test coverage never got wired in).

Be aggressive about catching failure before deploy — this job runs in
2 minutes, deploy takes 45 seconds. Doubling down on fast feedback
here is cheap.

### `build-publish`

Identical across repos:

```yaml
build-publish:
  runs-on: ubuntu-latest
  needs: test
  permissions:
    contents: read
    packages: write
  steps:
    - uses: actions/checkout@v4
    - uses: docker/login-action@v3
      with:
        registry: ghcr.io
        username: ${{ github.actor }}
        password: ${{ secrets.GITHUB_TOKEN }}
    - run: name=coilysiren-<NAME> make .build-docker
    - run: docker tag coilysiren-<NAME>:latest ghcr.io/${{ github.repository }}/coilysiren-<NAME>:${{ github.sha }}
    - run: docker push ghcr.io/${{ github.repository }}/coilysiren-<NAME>:${{ github.sha }}
```

- **No `docker/setup-buildx-action`** — plain `docker build
  --build-arg BUILDKIT_INLINE_CACHE=1` is enough. Buildx was removed
  as unnecessary.
- `<NAME>` is the repo name (e.g. `galaxy-gen`), not
  `coilysiren/galaxy-gen`. See the Makefile `$(name-dashed)` rule.

### `deploy`

```yaml
deploy:
  runs-on: ubuntu-latest
  needs: build-publish
  steps:
    - uses: actions/checkout@v4
    # The action auths with an ephemeral authkey and brings tailscale up.
    # A second `sudo tailscale up` would try to reauth without a key
    # and hang for 6h. Push flags into the action's inputs instead.
    # Hostname is per-run to avoid machine-key collisions.
    - uses: tailscale/github-action@v3
      with:
        oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
        oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
        tags: tag:ci
        args: --accept-dns --accept-routes
        hostname: github-actions-${{ github.run_id }}
    - name: kubectl
      run: |
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    - name: kubeconfig
      run: |
        mkdir -p ~/.kube
        cat <<EOF > ~/.kube/config
        apiVersion: v1
        kind: Config
        clusters:
        - name: default
          cluster:
            server: ${{ secrets.K8S_SERVER }}
            certificate-authority-data: ${{ secrets.K8S_CA_DATA }}
        contexts:
        - name: default
          context: {cluster: default, user: default}
        current-context: default
        preferences: {}
        users:
        - name: default
          user:
            client-certificate-data: ${{ secrets.K8S_CLIENT_CERT_DATA }}
            client-key-data: ${{ secrets.K8S_CLIENT_KEY_DATA }}
        EOF
    - run: make .deploy
    - name: rollout status
      env:
        NS: coilysiren-<NAME>
        DEP: coilysiren-<NAME>-app
      run: kubectl -n "$NS" rollout status deployment/"$DEP" --timeout=10m
    - name: rollout diagnostics on failure
      if: failure()
      env:
        NS: coilysiren-<NAME>
        DEP: coilysiren-<NAME>-app
      run: |
        echo "::group::pods"
        kubectl -n "$NS" get pods -o wide || true
        echo "::endgroup::"
        echo "::group::describe deployment"
        kubectl -n "$NS" describe deployment "$DEP" || true
        echo "::endgroup::"
        echo "::group::describe pods"
        kubectl -n "$NS" describe pods -l app="$DEP" || true
        echo "::endgroup::"
        echo "::group::events"
        kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -50 || true
        echo "::endgroup::"
        echo "::group::logs (current)"
        kubectl -n "$NS" logs --tail=200 -l app="$DEP" --all-containers=true || true
        echo "::endgroup::"
        echo "::group::logs (previous)"
        kubectl -n "$NS" logs --tail=200 -l app="$DEP" --all-containers=true --previous || true
        echo "::endgroup::"
```

`make .deploy` is just `envsubst < deploy/main.yml | kubectl apply -f -` -
it returns as soon as the API server accepts the manifest, not when new
pods are Ready. The `rollout status` step is what gates job success on
the actual rollout: `ImagePullBackOff`, crash-looping pods, or readiness
probe failures fail the job inside 10 minutes instead of being silently
green. The `if: failure()` diagnostics block dumps pods/events/logs so
the GHA log has enough context to triage without ssh'ing to kai-server.
10 minutes accounts for slow GHCR pulls over the homelab's residential
uplink. No separate push-back channel from the cluster is needed.

Known divergences the next migration should fix:

- **backend** and **eco-mcp-app** still have the old two-step pattern:
  `tailscale/github-action@v3` + a separate `sudo tailscale up …`.
  That second `up` hangs 6 hours on v3 — see `f7cd461 CI: drop the
  redundant tailscale up that was hanging`. Fold their flags into the
  action inputs.
- Do **not** add `docker/setup-buildx-action` "for cache speed" —
  we've taken it out twice already.
- Do **not** override the image URL via `make .deploy
  image-url="$IMAGE_URL"` (galaxy-gen tried that and hit the
  dash-in-bash-var issue `142bd48`). The Makefile computes
  `image-url` from `git-hash` automatically.

## 5. Canonical k8s manifest shape

Authoritative: `eco-jobs-tracker/deploy/main.yml`. `envsubst`
variables: `${NAME}` (the dashed repo name, e.g.
`coilysiren-galaxy-gen`), `${DNS_NAME}` (e.g.
`galaxy-gen.coilysiren.me`), `${IMAGE}` (the GHCR URL with SHA tag).

Order matters: Namespace → (optional) ExternalSecret for GHCR pull →
Deployment → Service → Ingress.

### Namespace (self-bootstrapping)

```yaml
apiVersion: v1
kind: Namespace
metadata: {name: ${NAME}}
```

Keep this in `main.yml`, don't split into a separate `kubectl apply`
step. eco-mcp-app `38bcc65 fix(deploy): self-bootstrap namespace in
main.yml` — before this, a new repo needed `make deploy-namespace`
run manually before anything else worked.

### ExternalSecret for GHCR pull (for private images)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: docker-registry, namespace: ${NAME}}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: aws-parameter-store, kind: ClusterSecretStore}
  target:
    name: docker-registry
    creationPolicy: Owner
    template:
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |
          {"auths":{"ghcr.io":{"auth":"{{ printf "coilysiren:%s" .pat | b64enc }}"}}}
  data:
    - secretKey: pat
      remoteRef: {key: /github/pat}
```

Omit entirely if the GHCR package is public. eco-mcp-app briefly made
theirs public (`38bcc65`) then reverted to private with the
ExternalSecret pattern (`6f581f7`) — the declarative synthesis
replaces the old `make deploy-secrets-docker-repo` manual bootstrap.

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${NAME}-app, namespace: ${NAME}, labels: {app: ${NAME}-app}}
spec:
  selector: {matchLabels: {app: ${NAME}-app}}
  template:
    metadata: {labels: {app: ${NAME}-app}}
    spec:
      imagePullSecrets: [{name: docker-registry}]
      # Required for any pod that resolves *.coilysiren.me — home
      # router doesn't support hairpin NAT, so DNS→public IP→NAT dies.
      hostAliases:
        - ip: "192.168.0.194"
          hostnames: ["eco.coilysiren.me"]
      containers:
        - name: ${NAME}
          image: ${IMAGE}
          resources:
            requests: {cpu: "50m",  memory: "128Mi"}
            limits:   {cpu: "500m", memory: "256Mi"}
          env: [{name: PORT, value: "80"}]
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /healthz, port: 80}
            initialDelaySeconds: 2
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /healthz, port: 80}
            initialDelaySeconds: 10
            periodSeconds: 30
```

`hostAliases` is on every pod that talks to any `*.coilysiren.me`
inside the cluster. eco-mcp-app `1a885ea` added it after hitting
hairpin NAT.

Backend bumps limits to `1/512Mi` in `f56ac12 deploy: add resource
requests, bump memory, drop vestigial ingress annotations`.

### Service (tailscale-exposed ClusterIP)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}-service
  namespace: ${NAME}
  annotations: {tailscale.com/expose: "true"}
spec:
  type: ClusterIP
  selector: {app: ${NAME}-app}
  ports: [{port: 80, targetPort: 80, protocol: TCP}]
```

The `tailscale.com/expose` annotation tells the tailscale-operator
that already runs in the cluster to stand up a ts-proxy StatefulSet
so tailnet peers can reach this Service at a MagicDNS name without
going through the public ingress. Useful for debugging.

### Ingress (traefik + cert-manager DNS-01)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${NAME}-ingress
  namespace: ${NAME}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-production
    kubernetes.io/tls-acme: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${DNS_NAME}]
      secretName: ${NAME}-tls
  rules:
    - host: ${DNS_NAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: ${NAME}-service, port: {number: 80}}
```

`cert-manager.io/cluster-issuer: letsencrypt-production` is the
DNS-01 issuer (see §10). Don't add
`acme.cert-manager.io/http01-edit-in-place` — vestigial after the
DNS-01 migration, `f56ac12` stripped it. Don't duplicate
`ingressClassName` as an annotation — the `spec.ingressClassName`
field is canonical.

## 6. Canonical Makefile shape

Every deployable repo has the same deploy-shaped Makefile (Rust
repos use `makefile`; Python repos use `Makefile`).

### Config ingestion via yq

```make
dns-name    ?= $(shell cat config.yml | yq e '.dns-name')
email       ?= $(shell cat config.yml | yq e '.email')
name        ?= $(shell cat config.yml | yq e '.name')
name-dashed ?= $(subst /,-,$(name))
git-hash    ?= $(shell git rev-parse HEAD)
image-url   ?= ghcr.io/$(name)/$(name-dashed):$(git-hash)
```

`name` is the repo path (`coilysiren/galaxy-gen`); `name-dashed` is
that with `/` → `-` (`coilysiren-galaxy-gen`), which becomes the k8s
namespace and container name.

### `.build-docker`

```make
.build-docker:
	docker build --progress plain --build-arg BUILDKIT_INLINE_CACHE=1 \
	  --cache-from $(name):latest \
	  -t $(name):$(git-hash) -t $(name):latest .
```

The `--cache-from` is useful locally; in CI there's no cached image
to pull, which is fine — the build just won't hit it.

### `.publish`, `.deploy`, `.deploy-ssh`

```make
.publish:
	docker tag $(name):$(git-hash) $(image-url)
	docker push $(image-url)

.deploy:
	env NAME=$(name-dashed) DNS_NAME=$(dns-name) IMAGE=$(image-url) \
	  envsubst < deploy/main.yml | kubectl apply -f -
	kubectl rollout status deployment/$(name-dashed)-app -n $(name-dashed) --timeout=5m

# Fallback path for when the direct kubectl route is unavailable
# (e.g. tailnet ACL changes). Pipes the rendered manifest over SSH
# and uses kai-server's own kubectl.
.deploy-ssh:
	env NAME=$(name-dashed) DNS_NAME=$(dns-name) IMAGE=$(image-url) \
	  envsubst < deploy/main.yml | \
	  ssh -o StrictHostKeyChecking=accept-new \
	      -o UserKnownHostsFile=/dev/null \
	      kai@kai-server \
	      'kubectl --kubeconfig=/home/kai/.kube/config apply -f -'
```

### `deploy-secrets-docker-repo` (manual bootstrap)

```make
github-token := $(shell aws ssm get-parameter --name "/github/pat" \
  --with-decryption --query "Parameter.Value" --output text)

deploy-secrets-docker-repo:
	kubectl create secret docker-registry docker-registry \
	  --namespace="$(name-dashed)" \
	  --docker-server=ghcr.io/$(name) \
	  --docker-username=$(name) \
	  --docker-password=$(github-token) \
	  --dry-run=client -o yaml | kubectl apply -f -
```

Only needed for namespaces that don't have the ExternalSecret in
their `main.yml`.

## 7. Known traps, with symptom and fix

One line per trap. Every fix here has a commit in some repo's history.

- **`WebAssembly.Table.grow() failed` in browser** → apt's binaryen
  is ancient and mis-optimizes. Pin to upstream release 119 binary.
  (galaxy-gen `8a4bd98`)
- **`K8S_SERVER` set to `https://kai-server:6443`** → kubectl hangs.
  MagicDNS doesn't resolve in GH runners. Use
  `https://<KAI_SERVER_TAILNET_IP>:6443`. (galaxy-gen `1189234`)
- **Deploy times out at `kubectl apply`** → you synced
  `TS_OAUTH_*` from `/tailscale/k3s/*` instead of `/tailscale/*`.
  The k3s-named ones have the wrong ACL. Re-sync from the
  non-`/k3s/` path.
- **`sudo tailscale up` hangs 6 hours** → `tailscale/github-action@v3`
  already brought tailscale up with a single-use key. The second `up`
  tries to reauth and deadlocks. Fold flags into the action's
  `args` / `hostname` inputs. (eco-jobs-tracker `f7cd461`)
- **Pod can't reach `eco.coilysiren.me`** → home router has no
  hairpin NAT. Add `hostAliases` pinning the hostname to
  `192.168.0.194`. (eco-mcp-app `1a885ea`)
- **App code calls `boto3.client("ssm").get_parameter(...)` at
  runtime and silently gets nothing** → pods don't have AWS
  credentials (only the `external-secrets` namespace does, via the
  hand-placed `aws-credentials` Secret). The SSM param exists and
  `aws ssm describe-parameters` from your laptop sees it, but the
  pod can't. Don't give app pods AWS creds — instead add an
  `ExternalSecret` block to `main.yml` syncing the param into a K8s
  Secret, then mount it via `env.valueFrom.secretKeyRef`. (eco-mcp-app
  `ECO_ADMIN_TOKEN` for the economy card.)
- **HTTP-01 challenges fail** → hairpin NAT again. Migrate to
  DNS-01 via Route 53. (infrastructure `db41a7c`, `77a3fb7`)
- **`error: x509: certificate signed by unknown authority`** →
  `K8S_CA_DATA` stale. Refresh from kai-server's kubeconfig.
- **`error: You must be logged in to the server (Unauthorized)`** →
  the k3s client cert rotated (default ~1y). Re-sync all three
  `K8S_CLIENT_*` secrets together.
- **`ImagePullBackOff` on new namespace** → `docker-registry` Secret
  missing. Either add the ExternalSecret block in `main.yml` or run
  `make deploy-secrets-docker-repo` once.
- **Make target fails on `image-url=foo make …`** → bash rejects
  `image-url=` as env prefix because `-` isn't a valid bash var
  character. Use `make target image-url=foo` (Make-level arg).
  (galaxy-gen `142bd48`)
- **`docker/setup-buildx-action` added "for perf"** → removed. Plain
  `docker build` + `BUILDKIT_INLINE_CACHE=1` is enough.
- **Namespace must exist before ExternalSecret applies** → keep
  Namespace as the first document in `main.yml`.
- **Redundant `docker login` before `make .deploy`** → dropped.
  (backend `6e2695e`)
- **`acme.cert-manager.io/http01-edit-in-place` annotation** →
  vestigial post-DNS-01 migration. (f56ac12)
- **`spec.ingressClassName` duplicated with annotation form** →
  drop the annotation.
- **Resolving `kai-server` at runtime via `tailscale status --json`** →
  overcomplicated symptom-chasing. The fix is in the
  `K8S_SERVER` secret value. (galaxy-gen `1189234` reverts three
  prior commits of chasing this.)
- **CoreDNS ConfigMap edits disappear after k3s restart** → k3s
  addon reconciler overwrites kube-system manifests. Use the
  `coredns-custom` ConfigMap import mechanism instead.
- **Stale `docker-registry` secret causing `ImagePullBackOff` for
  minutes after a rotation** → bounce the deployment:
  `kubectl rollout restart deployment/${NAME}-app -n ${NAME}`.
- **Host-userspace process on kai-server (e.g. `eco-server.service`)
  can't reach a tailnet IP that belongs to a ts-proxy running on the
  same host** → tailnet loopback gap. Same URL works fine from any
  off-host tailnet peer (laptop, phone). Symptom is a 5s connect
  timeout from in-process HTTP, no packets observed at the ts-proxy
  pod. Fix: add a NodePort sibling Service (the tailnet-exposed
  ClusterIP can't double as one) and point the host-userspace client
  at `http://localhost:<nodePort>/...`. k3s installs host-level
  iptables for NodePorts so traffic never touches `tailscale0`. The
  ts-proxy stays in place for off-host access. Reference manifest:
  `deploy/observability/vmsingle-nodeport-service.yml`.
  (coilysiren/infrastructure#71, eco-telemetry#5)
- **`ExternalSecret` in an app namespace stuck on `SecretSyncedError:
  aws-credentials not found`** → the `ClusterSecretStore`'s auth
  `secretRef` must pin `namespace: external-secrets` on both
  `accessKeyIDSecretRef` and `secretAccessKeySecretRef`. Without it,
  ClusterSecretStore looks for `aws-credentials` in the *consuming*
  namespace (where it doesn't exist — only `external-secrets` has the
  hand-placed bootstrap Secret). Fix lives in
  `infrastructure/deploy/secretstore.yml`; apply with
  `kubectl apply -f deploy/secretstore.yml`. Symptom also includes the
  pod stuck on `CreateContainerConfigError: secret "${NAME}-fred" not
  found` because the downstream Secret never renders.
- **`coilysiren-pull-all` leaves Git LFS pointer files in a checkout**
  → kai-server had no `git-lfs`, so `git pull --ff-only` skipped the
  smudge filter and wrote pointer text where binary assets (`.glb`,
  `.zip`, …) should be. The eco-mods rsync deploy then ships broken
  assets. Fix: `coily ssh kai-server -- coily pkg brew install git-lfs
  --allow-untapped`, then the `git lfs install --skip-repo` at the top
  of `coilysiren-pull-all.sh` wires the global smudge/clean filters on
  every run. Re-smudge an already-degraded file with
  `git checkout -- <path>` once the filters are wired.
  (coilysiren/infrastructure#286)

## 8. First-time setup checklist for a new repo

1. **Route 53 A record**: `<service>.coilysiren.me` → `<HOME_PUBLIC_IP>`
   in zone `Z06714552N3MO04UBWF33`. One-time.
2. **Tailscale OAuth secrets**:
   ```bash
   aws ssm get-parameter --name /tailscale/oauth-client-id \
     --with-decryption --query Parameter.Value --output text \
     | gh secret set TS_OAUTH_CLIENT_ID --repo coilysiren/<repo>
   aws ssm get-parameter --name /tailscale/oath-secret \
     --with-decryption --query Parameter.Value --output text \
     | gh secret set TS_OAUTH_SECRET --repo coilysiren/<repo>
   ```
   **Not** `/tailscale/k3s/*`.
3. **K3s kubeconfig material** — from kai-server's
   `/home/kai/.kube/config`, pipe each field into its GH secret (see
   §3).
4. **`K8S_SERVER`**:
   ```bash
   gh secret set K8S_SERVER --repo coilysiren/<repo> \
     --body 'https://<KAI_SERVER_TAILNET_IP>:6443'
   ```
5. **`config.yml`** at repo root:
   ```yaml
   dns-name: <service>.coilysiren.me
   email: coilysiren@gmail.com
   name: coilysiren/<repo>
   # port: 4100   # if you want a dev-server port
   ```
6. **`Dockerfile`** — `EXPOSE $PORT` and `CMD` that honours `$PORT`.
7. **`deploy/main.yml`** — copy from eco-jobs-tracker; add
   `hostAliases` if the pod will talk to any `*.coilysiren.me`.
8. **`Makefile`** (or `makefile`) — copy from eco-jobs-tracker;
   adjust the container name in the `.build-docker` invocation.
9. **`.github/workflows/build-and-publish.yml`** — copy byte-for-byte
   from eco-jobs-tracker; change the `name=coilysiren-<name>` arg in
   the `.build-docker` step.
10. **First push to `main`.** Watch `gh run watch`. Expected: test →
    build-publish → deploy all green within ~2-3 minutes. The first
    ingress apply will take cert-manager 1-2 minutes to issue a LE
    cert via DNS-01 before HTTPS works.

## 9. Failure triage tree

- **Deploy times out at `kubectl apply` (60s TCP timeout)**
  → is `K8S_SERVER` set to `https://<KAI_SERVER_TAILNET_IP>:6443`?
  → is tailnet ACL granting `tag:ci` access to the node's `:6443`?
  → are `TS_OAUTH_*` synced from `/tailscale/*`, not `/tailscale/k3s/*`?
- **Deploy hangs 6h on `sudo tailscale up`**
  → you have a redundant second `tailscale up` after the v3 action;
  fold its flags into the action's `args`/`hostname` inputs.
- **`error: x509: certificate signed by unknown authority`**
  → `K8S_CA_DATA` stale; refresh from kai-server.
- **`error: You must be logged in to the server (Unauthorized)`**
  → client cert expired; refresh `K8S_CLIENT_CERT_DATA` +
  `K8S_CLIENT_KEY_DATA` together with `K8S_CA_DATA`.
- **`ImagePullBackOff` after deploy**
  → is the ExternalSecret in `main.yml` syncing `docker-registry`
  in the new namespace? If no, run
  `make deploy-secrets-docker-repo`.
- **Pod crashes with DNS errors for `eco.coilysiren.me`**
  → add the `hostAliases` block pinning to `192.168.0.194`.
- **Cert stuck at `Challenge pending`**
  → `dig _acme-challenge.<host> TXT` — did Route 53 land the record?
  → is the `route53-coilysiren-me` IAM policy still attached to the
  cert-manager IRSA/IAM user?
  → wait 1-2 minutes, Route 53 propagation can be slow.
- **Cert issued but browser sees LE staging cert**
  → Ingress annotation says `letsencrypt-staging`; switch to
  `letsencrypt-production`.
- **`make .build-docker` fails with weird flag parse**
  → shell var name has `-` in it; pass as Make arg
  (`name=foo make .build-docker`), not shell env.
- **WASM `Table.grow()` error after a fresh deploy**
  → binaryen from apt; install release 119 binary in the workflow
  (`curl -sSL https://github.com/WebAssembly/binaryen/releases/download/version_119/binaryen-version_119-x86_64-linux.tar.gz`).
- **kubectl from laptop can't reach cluster**
  → `tailscale up` first. Then `ssh kai@kai-server` works from the
  tailnet.
- **`make .deploy` says `namespace/<foo> unchanged, deployment
  configured, service unchanged, ingress unchanged` but site still
  shows old version**
  → deployment config didn't change because image tag is the same
  (Makefile defaults `git-hash` to HEAD). Bump a commit and retry.
- **A repo deployed via rsync ships tiny text files where binary
  assets (`.glb`, `.zip`, …) should be**
  → the checkout has Git LFS pointer files. Is `git-lfs` installed on
  kai-server? Did `coilysiren-pull-all.sh` log the
  `git-lfs not installed` warning? Install it (`coily pkg brew install
  git-lfs --allow-untapped`), re-run pull-all to wire the filters, then
  `git checkout -- <path>` to re-smudge the degraded files.

## 10. Lore / load-bearing notes

- **Why `K8S_SERVER` is the tailnet IP, not hostname**: MagicDNS
  does not resolve inside GitHub Actions runners even with
  `--accept-dns`. LAN IP is unreachable from outside the house. The
  tailnet IP is the one address in the cert's SAN list that the
  runner can actually route to.
- **Why `hostAliases` for `*.coilysiren.me`**: `pod → eco.coilysiren.me
  → public IP → NAT → dead`. Home router has no hairpin NAT. Pin to
  `192.168.0.194` so the pod stays inside the LAN.
- **Why cert-manager uses DNS-01, not HTTP-01**: same hairpin NAT
  problem. cert-manager's HTTP-01 self-check loops through the public
  IP and dies. DNS-01 via Route 53 bypasses the network entirely.
  The old HTTP-01 saga is retired in infrastructure `77a3fb7 k8s:
  rip out cert_manager_loopback_fix, never again`.
- **Current `infrastructure/deploy/cert_manager.yml` still shows
  HTTP-01 solvers** — stale; the running cluster uses DNS-01.
  Source of truth is the live `ClusterIssuer` resource in the
  cluster, not the checked-in manifest. Refresh before editing.
- **Why the `/tailscale/oath-*` typo is load-bearing**: the SSM
  param was created with the typo. Rewriting it would break the
  working path; the `/tailscale/k3s/oauth-*` variant is the
  "correctly spelled" one but has an ACL that denies what CI
  needs.
- **Why `/tailscale/k3s/*` looks tempting but isn't**: name says
  "k3s" so you assume it's the one for k3s deploys. In reality
  the ACL on it is tighter, and the CI-facing OAuth client lives
  at the non-`/k3s/` path. This has bitten at least twice.
- **Why k3s used to bind localhost only**: older k3s default.
  Since fixed — SANs now cover `<KAI_SERVER_TAILNET_IP>` + `kai-server` +
  `127.0.0.1` + `192.168.0.194`. The `.deploy-ssh` Makefile target
  exists because of that older reality; kept as emergency
  fallback.
- **Why the Tailscale authkey is single-use**: the action's `tags:
  tag:ci` requests an ephemeral, single-use key. Any `tailscale up`
  after exhausts the key and tries interactive reauth, which is
  what causes the 6h hang.
- **Why per-run hostname**: machine-key collisions across
  concurrent CI runs on the same auth client.
- **IAM breakdown**: `kai-server-k3s` user is in groups
  `ssm-read-only` (for external-secrets to read SSM) and
  `route53-coilysiren-me` (for cert-manager DNS-01, scoped to the
  coilysiren.me zone only). Bootstrap credentials for
  external-secrets are a Kubernetes Secret
  `external-secrets/aws-credentials` — hand-placed, not synced.
- **On-host kubectl setup**: by default `kai@kai-server`'s
  `~/.kube/config` is empty. To enable `make deploy*` targets
  locally on kai-server:
  ```bash
  sudo chmod 644 /etc/rancher/k3s/k3s.yaml
  cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  ```
  (k3s detects its argv[0]).
- **Commit subject convention**: `deploy:` / `CI:` / `wasm:`
  prefixes so `git log --grep=deploy` stays useful. Every deploy
  commit cited in this doc follows it.
- **The authoritative deploy shape is `eco-jobs-tracker`** (renamed
  from `eco-spec-tracker` 2026-05-02; deploy internals like the k8s
  namespace `coilysiren-eco-spec-tracker` and Python package
  `eco_spec_tracker` are still on the old name), not
  `backend`. Backend set the pattern but hasn't been touched since
  the pre-DNS-01 era; eco-jobs-tracker has the fresher shape after
  `49f99e4 CI: revert to backend-shape direct kubectl deploy`.
  galaxy-gen's `bddec18 workflow: match eco-spec-tracker
  byte-for-byte` codifies that eco-jobs-tracker is canon.

---

## Change log

- 2026-04-21 — initial writeup after the four-repo mess
  (galaxy-gen's CI landing). Compiled from commits across
  `backend`, `eco-mcp-app`, `eco-spec-tracker`, `galaxy-gen`,
  `kai-server`, `infrastructure`, plus the session transcripts
  stored locally under `~/.claude/projects/…/memory/`.
- 2026-05-22 — wired Git LFS into `coilysiren-pull-all.sh` after
  eco-mods adopted LFS, so the daily pull fetches real content.
  (#286)
