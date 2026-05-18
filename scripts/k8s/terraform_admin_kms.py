#!/usr/bin/env python3
"""Run terraform against `terraform/admin-kms/`.

No secret inputs - admin principal/group lives in terraform.tfvars and
is not sensitive. AWS creds come from the caller's shell.

Usage: terraform_admin_kms.py [action]   # default: plan
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if action == "init":
        run("terraform -chdir=terraform/admin-kms init")
        return
    run(f"terraform -chdir=terraform/admin-kms {action}")


if __name__ == "__main__":
    main()
