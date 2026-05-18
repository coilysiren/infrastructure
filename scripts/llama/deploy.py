#!/usr/bin/env python3
"""Apply llama/deploy.yml into the llama namespace."""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402


def main():
    run("kubectl create namespace llama", warn=True)
    run("kubectl apply -f llama/deploy.yml")


if __name__ == "__main__":
    main()
