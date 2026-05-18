#!/usr/bin/env python3
"""Print the auto-generated Grafana admin password."""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402


def main():
    run(
        "kubectl get secret -n observability grafana "
        "-o jsonpath='{.data.admin-password}' | base64 -d"
    )


if __name__ == "__main__":
    main()
