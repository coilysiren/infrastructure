#!/usr/bin/env python3
"""Run terraform against `terraform/grafana/` to manage Grafana dashboards.

Pulls the admin password from SSM (/grafana/admin-password) and exports
GRAFANA_URL + GRAFANA_AUTH for the grafana provider. The plaintext
password is passed to terraform via env, never echoed or persisted.

Usage: terraform_grafana.py [action]   # default: plan
"""
# pylint: disable=wrong-import-position
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import ssm, terraform_run  # noqa: E402


def main():
    password = ssm().get_parameter(
        Name="/grafana/admin-password",
        WithDecryption=True,
    )["Parameter"]["Value"]
    env = os.environ.copy()
    env["GRAFANA_URL"] = "https://grafana.coilysiren.me"
    env["GRAFANA_AUTH"] = f"admin:{password}"
    terraform_run("grafana", env=env)


if __name__ == "__main__":
    main()
