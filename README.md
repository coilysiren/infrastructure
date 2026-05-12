# infrastructure

Everything Kai needs to stand up and operate **kai-server**. Systemd units, shell scripts, k3s cluster manifests, and a small set of coily verbs for cluster-side bootstrap.

## Layout

```
.
├── caddy/            # (legacy, pre-traefik caddy config)
├── deploy/           # cluster-wide manifests applied via coily verbs
│   ├── cert_manager.yml     # cert-manager ClusterIssuers (DNS-01 via Route 53)
│   ├── externalsecret.yml   # external-secrets sync rules
│   └── secretstore.yml      # SecretStore -> AWS SSM Parameter Store
├── docs/             # durable ops documentation
├── llama/            # llama-service k8s manifests
├── scripts/          # systemd unit ExecStart/ExecPre scripts + Python helpers for coily verbs
├── systemd/          # systemd unit files
├── Makefile          # entry points for coily verbs
└── eco.md            # Eco server configuration notes
```

## Operating the cluster

Cluster-bootstrap verbs are declared in [`.coily/coily.yaml`](.coily/coily.yaml) and driven by `Makefile` targets that call `scripts/k8s.py` / `scripts/llama.py`. Common verbs:

```bash
coily cert-manager                                                        # re-apply cert-manager + ClusterIssuers
coily aws-secrets aws_access_key_id=<ID> aws_secret_access_key=<SECRET>   # bootstrap external-secrets + aws-credentials
coily observability                                                       # install / upgrade VictoriaMetrics + Grafana
coily terraform-grafana action=plan                                       # plan / apply Grafana dashboards via terraform
```

K3s service ops and game-server systemd ops live in coily core. Restart k3s with `coily ssh systemctl restart k3s.service`; tail / restart game servers with `coily gaming <eco|core-keeper|icarus|factorio> ...`.

See `docs/` for:

- `architecture.md` — top-down view of what runs on kai-server
- `certificates.md` — DNS-01 via Route 53 cert flow (no more HTTP-01 / hairpin-NAT hacks)

## Commands

Dev commands are declared in [`.coily/coily.yaml`](.coily/coily.yaml). Run them as `coily exec <verb>`.

## See also

- [AGENTS.md](AGENTS.md) - agent-facing operating rules.
- [docs/FEATURES.md](docs/FEATURES.md) - inventory of what ships today.
- [.coily/coily.yaml](.coily/coily.yaml) - allowlisted commands. Agents route through coily, not bare `make` / `uv` / `python` / `npm` / `cargo` / `dotnet`.

Cross-reference convention from [coilysiren/coilyco-ai#313](https://github.com/coilysiren/coilyco-ai/issues/313).
