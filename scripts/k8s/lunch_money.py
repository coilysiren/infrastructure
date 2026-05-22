#!/usr/bin/env python3
"""Deploy or upgrade the lunch-money-k8s MCP server."""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402

# Chart lives in the sibling coilysiren/lunch-money-k8s checkout.
CHART = "../lunch-money-k8s/chart"


def main():
    run("kubectl apply -f deploy/lunch-money/secret.yml")
    run(
        f"helm upgrade --install lunch-money {CHART} "
        "--namespace lunch-money -f deploy/lunch-money/values.yaml"
    )


if __name__ == "__main__":
    main()
