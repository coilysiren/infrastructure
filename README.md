# infrastructure

Everything Kai needs to stand up and operate **kai-server** — systemd units, shell scripts, k3s cluster manifests, and a small invoke-based task runner.

## Layout

```
.
├── caddy/            # (legacy, pre-traefik caddy config)
├── deploy/           # cluster-wide manifests applied via `inv k8s.*` tasks
│   ├── cert_manager.yml     # cert-manager ClusterIssuers (DNS-01 via Route 53)
│   ├── externalsecret.yml   # external-secrets sync rules
│   └── secretstore.yml      # SecretStore -> AWS SSM Parameter Store
├── docs/             # durable ops documentation
├── eco-server/       # Eco game server configs
├── llama/            # llama-service k8s manifests
├── scripts/          # systemd unit ExecStart/ExecPre scripts
├── src/              # python source for the invoke tasks
├── systemd/          # systemd unit files
├── tasks.py          # invoke entry point
└── eco.md            # Eco server configuration notes
```

## Operating the cluster

Everything is driven from `tasks.py` via [pyinvoke](https://www.pyinvoke.org/). Run `inv -l` for a full list.

Common targets:

```bash
inv k8s.cert-manager       # re-apply cert-manager + ClusterIssuers
inv k8s.aws-secrets <id> <secret>  # bootstrap external-secrets + aws-credentials
inv k8s.service-restart    # restart k3s itself
```

See `docs/` for:

- `architecture.md` — top-down view of what runs on kai-server
- `certificates.md` — DNS-01 via Route 53 cert flow (no more HTTP-01 / hairpin-NAT hacks)
- `security.md` — readonly kubectl wrapper used by Claude Code sessions
