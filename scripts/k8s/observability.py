#!/usr/bin/env python3
"""Install or upgrade the VictoriaMetrics + Grafana stack in the
`observability` namespace. Idempotent; safe to re-run.

See deploy/observability/README.md for the full design.
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402


def main():
    run("helm repo add vm https://victoriametrics.github.io/helm-charts/", warn=True)
    run(
        "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
        warn=True,
    )
    # grafana/helm-charts deprecated the grafana chart on 2026-01-30 and
    # pointed users at grafana-community/helm-charts. Drop-in replacement.
    run(
        "helm repo add grafana-community https://grafana-community.github.io/helm-charts",
        warn=True,
    )
    run("helm repo update")

    run("kubectl apply -f deploy/observability/namespace.yml")
    run("kubectl apply -f deploy/observability/admin-password-externalsecret.yml")

    run(
        "helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter "
        "--namespace observability "
        "-f deploy/observability/node-exporter-values.yml"
    )
    run(
        "helm upgrade --install victoria-metrics vm/victoria-metrics-single "
        "--namespace observability "
        "-f deploy/observability/victoria-metrics-values.yml"
    )
    run(
        "helm upgrade --install vmagent vm/victoria-metrics-agent "
        "--namespace observability "
        "-f deploy/observability/vmagent-values.yml"
    )
    run(
        "helm upgrade --install grafana grafana-community/grafana "
        "--namespace observability "
        "-f deploy/observability/grafana-values.yml"
    )


if __name__ == "__main__":
    main()
