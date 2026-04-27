# repo-recall on kai-server (tailnet-only)

Sibling to [`k3s-deploy-notes.md`](k3s-deploy-notes.md). repo-recall does not
go through k3s. It runs as a host systemd unit alongside the game-server
units (eco/factorio/icarus/core-keeper) and is reachable only over the
tailnet via `tailscale serve`. No public DNS, no traefik, no cert-manager.

## Why not k3s

The tool walks `/home/kai/projects/coilysiren` and parses
`/home/kai/.claude/projects/*.jsonl`. Putting it in k3s would mean a wide
`hostPath` mount of `/home/kai`, plus piping `gh` auth into the pod. The
cost/benefit's wrong for a single-user dev tool. Host systemd is the right
shape.

## Pieces

- **Binary**: `/usr/local/bin/repo-recall`. Built from
  `/home/kai/projects/coilysiren/repo-recall` on kai-server (rust toolchain
  is present).
- **Unit**: [`systemd/repo-recall.service`](../systemd/repo-recall.service).
  Runs as `kai`, sets `REPO_RECALL_HOST=0.0.0.0` (the env var added in
  coilysiren/repo-recall#14), `REPO_RECALL_PORT=7777`,
  `REPO_RECALL_CWD=/home/kai/projects/coilysiren`.
- **Install script**:
  [`scripts/install-repo-recall.sh`](../scripts/install-repo-recall.sh).
  Idempotent. Builds + installs binary + installs unit + reloads + restarts.
- **Tailnet exposure**: one-shot `tailscale serve` invocation, see below.
- **Repo bootstrap**:
  [`scripts/clone-coilysiren-repos.sh`](../scripts/clone-coilysiren-repos.sh)
  populates `/home/kai/projects/coilysiren/`. Without this the dashboard
  has nothing to show.

## First-time setup on kai-server

```sh
# 1. Clone the active coilysiren repo set (run as kai)
bash /home/kai/projects/coilysiren/infrastructure/scripts/clone-coilysiren-repos.sh

# 2. Build + install the binary, drop the unit, start the service
sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-repo-recall.sh

# 3. Expose over tailscale (run once, as kai). `serve` config persists in
#    tailscaled state across reboots; no need to put this in a unit.
tailscale serve --bg --https=443 http://127.0.0.1:7777

# 4. Verify
tailscale serve status
curl -sf https://kai-server.<tailnet>.ts.net/api/scan-version
```

The `kai-server.<tailnet>.ts.net` hostname comes from MagicDNS - check
`tailscale status` for the exact name.

## Auth model

Tailnet membership IS the auth. `tailscale serve` (not `funnel`) is
tailnet-only by definition - the public internet cannot reach it. No
app-level login. If the tailnet ever gains a device that shouldn't see
session metadata, switch to header-based gating using the
`Tailscale-User-Login` request header that the proxy injects.

## Upgrades

Re-running `install-repo-recall.sh` rebuilds from the latest source in
`/home/kai/projects/coilysiren/repo-recall` and restarts the unit. Pull
new commits first:

```sh
git -C /home/kai/projects/coilysiren/repo-recall pull --ff-only
sudo bash /home/kai/projects/coilysiren/infrastructure/scripts/install-repo-recall.sh
```

The `clone-coilysiren-repos.sh` bootstrap script can be re-run any time to
fetch new commits across the whole repo set without auto-pulling dirty
trees.

## Why `REPO_RECALL_HOST=0.0.0.0` is safe here

The binary defaults to `127.0.0.1` because session metadata can leak
sensitive content (see `repo-recall/AGENTS.md` privacy section). Binding
`0.0.0.0` is only safe on a host where some other layer gates access. On
kai-server that layer is `tailscale serve`, which terminates TLS at
`:443` on the tailnet IP and forwards to `127.0.0.1:7777`. The home
router doesn't NAT 7777, so nothing on the public internet ever reaches
it; LAN peers could reach `192.168.0.194:7777` but the LAN itself is
trusted. If that assumption ever changes, drop `REPO_RECALL_HOST` (or
set it to `127.0.0.1`) and rely on the loopback-only default.

## Troubleshooting

- **`systemctl status repo-recall` shows the binary exiting immediately** →
  most likely `REPO_RECALL_CWD` doesn't exist yet. Run the clone script.
- **Dashboard reachable from kai-server (`curl 127.0.0.1:7777`) but not
  from tailnet peers** → `tailscale serve status` empty? Run the `serve`
  command from step 3 again. The config is per-node, persists in
  tailscaled state, but doesn't survive a fresh tailscaled install.
- **404s on every page** → check `REPO_RECALL_CWD` points at a tree that
  actually contains repos. Empty index = empty dashboard (not an error).
- **`gh` health warning banner** → run `gh auth login` as `kai` on
  kai-server; the `gh run list` outbound call needs it.
- **Cert diagnostics from kai-server itself show traefik's self-signed
  default cert, not the Let's Encrypt one** → expected, not a bug.
  k3s's svclb binds traefik to `0.0.0.0:443`, so a connection from the
  host loops back through traefik before tailscaled sees it. Always
  curl/openssl from a tailnet peer (laptop, phone) when checking the
  serve cert. The peer's traffic enters via the tailnet IP and
  tailscaled intercepts it before traefik.
