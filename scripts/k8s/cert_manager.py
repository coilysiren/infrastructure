#!/usr/bin/env python3
"""Install or refresh cert-manager + ClusterIssuers."""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import CERT_MANAGER_VERSION, run  # noqa: E402


def main():
    run(
        "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/"
        f"{CERT_MANAGER_VERSION}/cert-manager.yaml"
    )
    run("kubectl apply -f deploy/cert_manager.yml")


if __name__ == "__main__":
    main()
