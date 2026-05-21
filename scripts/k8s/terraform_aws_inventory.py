#!/usr/bin/env python3
"""Run terraform against `terraform/aws-inventory/`.

No secret inputs. The module is read-only (data sources only) and AWS
creds come from the caller's shell.

Usage: terraform_aws_inventory.py [action]   # default: plan

`action=output` is special: it runs `terraform output -json inventory`
and prints the inventory as YAML. Every other action passes straight
through to terraform via terraform_run (init, plan, apply, destroy).
"""
# pylint: disable=wrong-import-position
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import terraform_run  # noqa: E402

CHDIR = "terraform/aws-inventory"


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


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "output":
        show_output()
        return
    terraform_run("aws-inventory")


if __name__ == "__main__":
    main()
