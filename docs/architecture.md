# kai-server architecture

Single-node k3s on a home desktop, fronting a small set of personal services over both the public internet (via traefik + home public IP) and tailnet (via the Tailscale k8s operator).

`<HOME_PUBLIC_IP>` resolves from SSM `/coilysiren/home/public-ip`. `<KAI_SERVER_TAILNET_IP>` resolves from SSM `/coilysiren/kai-server/tailnet-ip`. See `docs/k3s-deploy-notes.md`.

```
Internet ─┐
          │
          ▼
   <HOME_PUBLIC_IP>:443  (home public IP, NAT -> 192.168.0.194)
          │
          ▼
   traefik LoadBalancer  (svclb-traefik daemonset routes host traffic in)
          │
          ▼
   Ingress: api.coilysiren.me  ──► coilysiren-backend-service ──► coilysiren-backend-app pod
                                        │
                                        └── TLS: coilysiren-backend-tls
                                            (cert-manager → Let's Encrypt → DNS-01 → Route 53)

Tailnet ──► tailscale-operator ──► ts-coilysiren-backend-service-* StatefulSet ──► same backend Service
```

## Namespaces

| Namespace | Contents |
|---|---|
| `kube-system` | k3s addons: traefik, coredns, metrics-server, local-path-provisioner, svclb |
| `cert-manager` | cert-manager controller, cainjector, webhook |
| `external-secrets` | external-secrets operator + its controller/webhook/cert-controller |
| `tailscale` | Tailscale operator + per-exposed-service proxy StatefulSets |
| `coilysiren-backend` | the `api.coilysiren.me` FastAPI service |

## Credentials / secrets

| Secret | Where | Source | Used by |
|---|---|---|---|
| `aws-credentials` | `external-secrets` ns | hand-placed bootstrap | external-secrets controller (to call AWS SSM and Route 53) |
| `route53-credentials` | `cert-manager` ns | hand-placed, mirrors `aws-credentials` | cert-manager DNS-01 solver |
| `github-pat` | `external-secrets` ns | SSM `/github/pat` via ExternalSecret | *(reserved; no workload currently references it)* |
| `docker-registry` | `coilysiren-backend` ns | `make deploy-secrets-docker-repo` in backend repo, reads SSM `/github/pat` | imagePullSecret for ghcr.io |

The underlying IAM user `kai-server-k3s` is in two groups:

- `ssm-read-only` — grants `ssm:GetParameter` across Parameter Store
- `route53-coilysiren-me` — grants `route53:ChangeResourceRecordSets` + `GetChange` + `ListResourceRecordSets`, scoped to `hostedzone/Z06714552N3MO04UBWF33` (`coilysiren.me`) only

## Services on the host (systemd)

Each game server has a `-pre.sh` and a `-start.sh` script. Pre scripts run `steamcmd` updates and any config edits; start scripts exec the binary.

- `k3s.service` — runs `scripts/k3s-start.sh`, which resolves the tailnet node-ip then `exec`s `/usr/local/bin/k3s server` so k3s becomes the unit's Main PID. The `exec` is required: under `Type=notify` + default `NotifyAccess=main` a non-`exec` child's `sd_notify READY` is dropped and the unit hangs in `activating` forever. Teardown is handled by the unit's `ExecStop` lines (#170)
- `core-keeper-server.service` — Core Keeper "Coily Keeper" world
- `eco-server.service` — Eco game server
- `factorio-server.service`, `icarus-server.service` — other game servers

## Workloads in k3s

See `deploy/` for the cluster-wide manifests and `llama/deploy.yml` for the llama-service.
