"""Shared helpers for the per-verb scripts under scripts/k8s/ and scripts/llama/.

Each verb script puts scripts/ on sys.path with a short cookie:

    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from _lib import run  # noqa: E402
"""

import shlex
import subprocess
import sys

import boto3


CERT_MANAGER_VERSION = "v1.12.16"


def ssm():
    return boto3.client("ssm", region_name="us-east-1")


def run(cmd, *, env=None, warn=False):
    """Echo + run a shell command. `warn=True` mirrors invoke's warn semantics
    (don't raise on non-zero exit)."""
    if isinstance(cmd, str):
        printable = cmd
        shell = True
    else:
        printable = " ".join(shlex.quote(c) for c in cmd)
        shell = False
    print(f"$ {printable}")
    result = subprocess.run(cmd, shell=shell, env=env, check=False)
    if result.returncode != 0 and not warn:
        sys.exit(result.returncode)
    return result
