# Observability stack — VictoriaMetrics + Grafana

Source-of-truth design doc: [`Notes/kai-server-o11y.md`](../../../coilyco-vault/Obsidian%20Vault/Notes/kai-server-o11y.md) in the vault.

Two panes:

- **Sentry** (existing, hosted) for app errors, app traces, app logs.
- **VictoriaMetrics + Grafana** (this directory) for host and app metrics on k3s.

## What this deploys

- `observability` namespace.
- **VictoriaMetrics single-node** (`vmsingle`) on `kai-server`, 10 GiB PVC on local-path. Tailnet-only (`tailscale.com/expose`). HTTP API on `:8428` for both queries and OTLP ingest.
- **vmagent** (separate `victoria-metrics-agent` chart, not bundled) scrapes node-exporter every 30s and remote-writes to vmsingle. Relabels `instance` to the k8s node name so the tailnet IP never lands on a graph.
- **prometheus-node-exporter** DaemonSet on every node. Defaults disable `systemd`/`processes`/`login` collectors; we additionally drop `wifi`/`hwmon`/`infiniband` (no signal, label noise).
- **Grafana** on `kai-server` with a 2 GiB PVC, public ingress at `https://grafana.coilysiren.me`, anon viewer **off**, VM datasource pre-provisioned, "Node Exporter Full" dashboard auto-imported.

## First-time install

DNS prereq: add `grafana.coilysiren.me` A record to `99.110.50.213` in Route 53 zone `Z06714552N3MO04UBWF33`. One-time.

Run from `infrastructure/` with kubectl context pointing at kai-server:

```bash
# 1. Helm repos
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update

# 2. Namespace
kubectl apply -f deploy/observability/namespace.yml

# 3. node-exporter DaemonSet (must exist before vmagent starts scraping)
helm install node-exporter prometheus-community/prometheus-node-exporter \
  --namespace observability \
  -f deploy/observability/node-exporter-values.yml

# 4. VictoriaMetrics + bundled vmagent
helm install victoria-metrics vm/victoria-metrics-single \
  --namespace observability \
  -f deploy/observability/victoria-metrics-values.yml

# 4b. vmagent (separate chart, not bundled with vmsingle)
helm install vmagent vm/victoria-metrics-agent \
  --namespace observability \
  -f deploy/observability/vmagent-values.yml

# 5. Grafana
helm install grafana grafana-community/grafana \
  --namespace observability \
  -f deploy/observability/grafana-values.yml

# 6. Retrieve the auto-generated admin password
kubectl get secret -n observability grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d ; echo
```

Watch the rollout:

```bash
kubectl get pods -n observability -w
kubectl get ingress -n observability
kubectl describe certificate -n observability grafana-tls
```

The cert can take 1-2 minutes to issue via DNS-01.

## Upgrade

After editing any `*-values.yml`:

```bash
helm upgrade <release> <chart> --namespace observability -f deploy/observability/<release>-values.yml
```

Where `<release>` is `node-exporter` / `victoria-metrics` / `grafana` and `<chart>` is the chart name from the install step.

## Uninstall

```bash
helm uninstall grafana node-exporter victoria-metrics --namespace observability
kubectl delete pvc -n observability --all   # PVCs survive helm uninstall
kubectl delete namespace observability
```

## Thermal heartbeat (host-side)

Tracked in [coilysiren/infrastructure#85](https://github.com/coilysiren/infrastructure/issues/85). Dual-push: VM/Grafana via the textfile collector, Sentry via cron monitor + threshold-breach events.

Wired components:

- `scripts/thermal-heartbeat.py` reads `sensors -j`, `nvme smart-log`, and `/sys/class/thermal/*`, then writes `/var/lib/node-exporter/textfile/thermal.prom` atomically.
- `systemd/thermal-heartbeat.{service,timer}` runs the script every 30s on each host that should report.
- `node-exporter-values.yml` mounts `/var/lib/node-exporter/textfile` read-only and points the textfile collector at it.
- Sentry side reads from `/etc/thermal-heartbeat.env` (not in git):

  ```
  SENTRY_CRON_URL=https://o<org>.ingest.sentry.io/api/<project>/cron/kai-server-thermal/<key>/
  SENTRY_DSN=https://<key>@o<org>.ingest.sentry.io/<project>
  ```

Bring-up on a node:

```bash
# Host-side prereqs.
sudo apt-get install -y lm-sensors nvme-cli
sudo sensors-detect --auto

# Drop the host bits in place (run from the repo checkout on the node).
sudo install -d -m 0755 -o root /var/lib/node-exporter/textfile
sudo install -m 0644 systemd/thermal-heartbeat.service /etc/systemd/system/
sudo install -m 0644 systemd/thermal-heartbeat.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now thermal-heartbeat.timer

# Apply the helm-values change so node-exporter mounts the textfile dir.
helm upgrade node-exporter prometheus-community/prometheus-node-exporter \
  --namespace observability \
  -f deploy/observability/node-exporter-values.yml
```

Verify:

```bash
# Latest sample from the host, served by the local node-exporter pod.
kubectl exec -n observability ds/node-exporter-prometheus-node-exporter -- \
  wget -qO- http://localhost:9100/metrics | grep node_thermal_

# Last run status on the host.
journalctl -u thermal-heartbeat.service -n 1 --no-pager
```

Then in Sentry, create a cron monitor with slug `kai-server-thermal`, schedule `* * * * *` (every minute, with a 1-min margin) since cron monitors don't have sub-minute granularity. The script pings every 30s so a 60s missed-checkin window means at least two missed beats are required to fire. An alert rule on `level:warning` + `logger:thermal-heartbeat` covers threshold-breach events.

## Where eco-telemetry will plug in

`eco-telemetry` writes OTLP HTTP. Point its `OtlpEndpoint` at vmsingle over the tailnet:

```
http://victoria-metrics-victoria-metrics-single-server.observability.svc:8428/opentelemetry/api/v1/push
```

(or via the tailscale-operator MagicDNS name once that proxy is up). No collector in the middle for v1.

## Sentry stays put

Errors, app traces, and app-emitted logs continue to flow into hosted Sentry via the SDK wiring landed across `backend`, `eco-mcp-app`, `eco-spec-tracker`, `eco-telemetry`, and `coily` on 2026-04-24. This stack is metrics-only.

## Known unknowns to revisit

- **Anon viewer on specific dashboards.** Default is OFF for everything. After a few weeks, decide which dashboards are safe to expose publicly via folder permissions (probably k3s topology / request-rate; never the host CPU/RAM time-series, which leaks presence).
- **vmalert.** Off for v1. Wire it when there's an alert worth firing.
- **Log collection.** Skipping VictoriaLogs / Loki entirely; Sentry has app logs and host-level logs aren't being chased.
- **kai-desktop-tower scheduling.** node-exporter runs on both nodes; vmagent + vmsingle + grafana are pinned to kai-server. Revisit if the desktop ever gets workloads worth observing locally.
