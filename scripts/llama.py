#!/usr/bin/env python3
# pylint: disable=duplicate-code
"""Llama deploy verbs.

Library of verb functions invoked directly from Makefile targets via
`uv run python -c 'from scripts.llama import VERB; VERB(...)'`. See
.coily/coily.yaml for the coily-facing surface.
"""

import shlex
import subprocess
import sys

import boto3


def _ssm():
    return boto3.client("ssm", region_name="us-east-1")


def run(cmd, *, warn=False):
    if isinstance(cmd, str):
        printable = cmd
        shell = True
    else:
        printable = " ".join(shlex.quote(c) for c in cmd)
        shell = False
    print(f"$ {printable}")
    result = subprocess.run(cmd, shell=shell, check=False)
    if result.returncode != 0 and not warn:
        sys.exit(result.returncode)
    return result


def deploy_secrets_docker_repo():
    github_token = _ssm().get_parameter(
        Name="/github/pat",
        WithDecryption=True,
    )["Parameter"]["Value"]
    run("kubectl create namespace llama", warn=True)
    run(
        f"echo {github_token} | docker login ghcr.io -u coilysiren/llama --password-stdin"
    )
    run(
        f"""
        kubectl create secret docker-registry docker-registry \
            --namespace=llama \
            --docker-server=ghcr.io/coilysiren/llama \
            --docker-username=coilysiren/llama \
            --docker-password={github_token} \
            --dry-run=client -o yaml | kubectl apply -f -
        """
    )


def deploy():
    run("kubectl create namespace llama", warn=True)
    run("kubectl apply -f llama/deploy.yml")


