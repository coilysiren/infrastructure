#!/usr/bin/env python3
"""Install or upgrade the SigNoz stack in the `observability` namespace.
Idempotent; safe to re-run.

SigNoz is the self-hosted OpenTelemetry pane (traces, logs, metrics on
ClickHouse). Private only - the UI is reached over Tailscale, never a
public ingress. See deploy/observability/README.md for the full design.
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402

# Pin the signoz chart. Bumps to a newer chart are deliberate edits here.
SIGNOZ_CHART_VERSION = "0.125.0"


def main():
    run("helm repo add signoz https://charts.signoz.io", warn=True)
    run("helm repo update")

    run("kubectl apply -f deploy/observability/namespace.yml")

    run(
        "helm upgrade --install signoz signoz/signoz "
        f"--version {SIGNOZ_CHART_VERSION} "
        "--namespace observability "
        "-f deploy/observability/signoz-values.yml"
    )

    # Standalone ts-proxy for tailnet-only UI access. Applied after the
    # chart so the helm-managed signoz Service it selects already exists.
    run("kubectl apply -f deploy/observability/signoz-tailscale-service.yml")


if __name__ == "__main__":
    main()
