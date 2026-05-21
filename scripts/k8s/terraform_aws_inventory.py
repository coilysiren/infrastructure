#!/usr/bin/env python3
"""Run terraform against `terraform/aws-inventory/`.

No secret inputs. AWS creds come from the caller's shell. The module
manages real resources (the coilysiren.me Route53 zone + records, two
S3 buckets), so `apply` is not auto-approved - a bad apply breaks DNS
for every coilysiren.me service. Review the `plan` first, then run
`apply` interactively so terraform's approval prompt has a TTY.

Usage: terraform_aws_inventory.py [action]   # default: plan

Two actions are special:

- `output` runs `terraform output -json inventory` and prints the
  inventory as YAML.
- `import` brings every S3 bucket, the Route53 zone, and all 13 record
  sets under management. The Route53 zone id is resolved from AWS at
  run time so no opaque id lands in code. Already-imported resources
  are skipped, so it is safe to re-run.

Every other action passes straight through to terraform via
terraform_run (init, plan, apply, destroy).
"""
# pylint: disable=wrong-import-position
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import terraform_run  # noqa: E402

import boto3  # noqa: E402

CHDIR = "terraform/aws-inventory"

S3_BUCKETS = ["coilysiren-assets", "kai-game-backups"]

# Route53 record name (relative to the zone, "" = apex) -> resource address.
# IDs are built as ZONEID_<fqdn>_<type> once the zone id is known.
ROUTE53_RECORDS = [
    ("", "A", "aws_route53_record.apex_a"),
    ("www", "CNAME", "aws_route53_record.www"),
    ("", "NS", "aws_route53_record.ns"),
    ("", "SOA", "aws_route53_record.soa"),
    ("eco", "A", 'aws_route53_record.home_a["eco"]'),
    ("eco-jobs-tracker", "A", 'aws_route53_record.home_a["eco-jobs-tracker"]'),
    ("eco-mcp", "A", 'aws_route53_record.home_a["eco-mcp"]'),
    ("factorio", "A", 'aws_route53_record.home_a["factorio"]'),
    ("galaxy-gen", "A", 'aws_route53_record.home_a["galaxy-gen"]'),
    ("grafana", "A", 'aws_route53_record.home_a["grafana"]'),
    ("", "TXT", 'aws_route53_record.txt["@"]'),
    ("_atproto", "TXT", 'aws_route53_record.txt["_atproto"]'),
    ("_discord", "TXT", 'aws_route53_record.txt["_discord"]'),
]


def _scalar(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    return '"' + str(value).replace('"', '\\"') + '"'


def _emit_yaml(value, indent=0) -> str:
    """Minimal YAML emitter for the inventory output. Handles the dict /
    list / scalar shapes terraform's -json output produces. No PyYAML
    dependency, matching the stdlib-only bias of the sibling scripts."""
    pad = "  " * indent
    if isinstance(value, dict):
        if not value:
            return " {}\n"
        out = "\n" if indent else ""
        for key, val in value.items():
            out += f"{pad}{key}:{_emit_yaml(val, indent + 1)}"
        return out
    if isinstance(value, list):
        if not value:
            return " []\n"
        out = "\n"
        for item in value:
            rendered = _emit_yaml(item, indent + 1).lstrip("\n")
            if isinstance(item, (dict, list)):
                out += f"{pad}- {rendered.lstrip(' ')}"
            else:
                out += f"{pad}-{rendered}"
        return out
    return f" {_scalar(value)}\n"


def show_output():
    result = subprocess.run(
        ["terraform", f"-chdir={CHDIR}", "output", "-json", "inventory"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)
    inventory = json.loads(result.stdout)
    print("# AWS resource inventory via terraform/aws-inventory.")
    print("# Generated from `terraform output`. No secret values.")
    print(_emit_yaml(inventory).lstrip("\n"), end="")


def _zone_id() -> str:
    """The coilysiren.me hosted zone id, resolved from AWS at run time so
    the opaque id never has to be checked in."""
    client = boto3.client("route53")
    for zone in client.list_hosted_zones()["HostedZones"]:
        if zone["Name"] == "coilysiren.me.":
            return zone["Id"].rsplit("/", 1)[-1]
    sys.exit("could not find the coilysiren.me hosted zone")


def _tf_import(address: str, resource_id: str):
    """Import one resource. Treat an already-managed resource as a no-op
    so the whole `import` action stays re-runnable."""
    print(f"import {address} <- {resource_id}")
    result = subprocess.run(
        ["terraform", f"-chdir={CHDIR}", "import", address, resource_id],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return
    if "Resource already managed by Terraform" in result.stderr:
        print(f"  already imported, skipping {address}")
        return
    sys.stderr.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)


def import_resources():
    for bucket in S3_BUCKETS:
        _tf_import(f'aws_s3_bucket.bucket["{bucket}"]', bucket)

    zone_id = _zone_id()
    _tf_import("aws_route53_zone.coilysiren_me", zone_id)

    for name, rtype, address in ROUTE53_RECORDS:
        fqdn = "coilysiren.me" if name == "" else f"{name}.coilysiren.me"
        _tf_import(address, f"{zone_id}_{fqdn}_{rtype}")

    print("import complete - run `action=plan` to confirm a clean diff")


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "plan"
    if action == "output":
        show_output()
        return
    if action == "import":
        import_resources()
        return
    # No auto_approve - the module owns live DNS. `apply` must be run
    # interactively so terraform's approval prompt gets a real TTY.
    terraform_run("aws-inventory")


if __name__ == "__main__":
    main()
