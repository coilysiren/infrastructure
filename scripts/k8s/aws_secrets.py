#!/usr/bin/env python3
"""Bootstrap external-secrets + aws-credentials.

Usage: aws_secrets.py <aws_access_key_id> <aws_secret_access_key>
"""
# pylint: disable=wrong-import-position
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _lib import run  # noqa: E402


def main():
    if len(sys.argv) != 3:
        print(
            f"usage: {sys.argv[0]} <aws_access_key_id> <aws_secret_access_key>",
            file=sys.stderr,
        )
        sys.exit(2)
    aws_access_key_id, aws_secret_access_key = sys.argv[1], sys.argv[2]

    run("helm repo add external-secrets https://charts.external-secrets.io")
    run("helm repo update")
    run("kubectl create namespace external-secrets", warn=True)
    run(
        "helm install external-secrets external-secrets/external-secrets "
        "--namespace external-secrets",
        warn=True,
    )
    run(
        "kubectl delete secret aws-credentials -n external-secrets --ignore-not-found",
        warn=True,
    )
    run(
        f"""kubectl create secret generic aws-credentials \
            --namespace external-secrets \
            --from-literal=aws_access_key_id={aws_access_key_id} \
            --from-literal=aws_secret_access_key={aws_secret_access_key}
        """,
        warn=True,
    )
    run("kubectl apply -f deploy/secretstore.yml")
    run("kubectl apply -f deploy/externalsecret.yml")
    run("kubectl rollout restart deployment external-secrets -n external-secrets")


if __name__ == "__main__":
    main()
