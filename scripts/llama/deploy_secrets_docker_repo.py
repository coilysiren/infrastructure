#!/usr/bin/env python3
"""Bootstrap the llama ghcr.io docker-registry secret from SSM /github/pat."""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run, ssm  # noqa: E402


def main():
    github_token = ssm().get_parameter(
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


if __name__ == "__main__":
    main()
