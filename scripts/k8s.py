#!/usr/bin/env python3
# pylint: disable=duplicate-code
"""K3s cluster operator verbs.

Subcommands replace the old tasks.py + src/k8s.py invoke layer. Driven
from Makefile targets, which are themselves driven from coily verbs.
See .coily/coily.yaml.

Systemd-unit ops for the k3s service itself, and for game-server units,
live in coily core (`coily ssh systemctl`, `coily gaming <game> ...`)
and are intentionally not exposed as verbs here.
"""

import argparse
import os
import shlex
import subprocess
import sys

import boto3


CERT_MANAGER_VERSION = "v1.12.16"


def _ssm():
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


def cert_manager():
    run(
        "kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/"
        f"{CERT_MANAGER_VERSION}/cert-manager.yaml"
    )
    run("kubectl apply -f deploy/cert_manager.yml")


def aws_secrets(aws_access_key_id: str, aws_secret_access_key: str):
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


def observability():
    """Install or upgrade the VictoriaMetrics + Grafana stack in the
    `observability` namespace. Idempotent; safe to re-run.

    See deploy/observability/README.md for the full design.
    """
    run("helm repo add vm https://victoriametrics.github.io/helm-charts/", warn=True)
    run(
        "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
        warn=True,
    )
    # grafana/helm-charts deprecated the grafana chart on 2026-01-30 and
    # pointed users at grafana-community/helm-charts. Drop-in replacement.
    run(
        "helm repo add grafana-community https://grafana-community.github.io/helm-charts",
        warn=True,
    )
    run("helm repo update")

    run("kubectl apply -f deploy/observability/namespace.yml")
    run("kubectl apply -f deploy/observability/admin-password-externalsecret.yml")

    run(
        "helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter "
        "--namespace observability "
        "-f deploy/observability/node-exporter-values.yml"
    )
    run(
        "helm upgrade --install victoria-metrics vm/victoria-metrics-single "
        "--namespace observability "
        "-f deploy/observability/victoria-metrics-values.yml"
    )
    run(
        "helm upgrade --install vmagent vm/victoria-metrics-agent "
        "--namespace observability "
        "-f deploy/observability/vmagent-values.yml"
    )
    run(
        "helm upgrade --install grafana grafana-community/grafana "
        "--namespace observability "
        "-f deploy/observability/grafana-values.yml"
    )


def observability_admin_password():
    """Print the auto-generated Grafana admin password."""
    run(
        "kubectl get secret -n observability grafana "
        "-o jsonpath='{.data.admin-password}' | base64 -d"
    )


def terraform_grafana(action: str = "plan"):
    """Run terraform against `terraform/grafana/` to manage Grafana dashboards.

    Pulls the admin password from SSM (/grafana/admin-password) and exports
    GRAFANA_URL + GRAFANA_AUTH for the grafana provider. The plaintext
    password is passed to terraform via env, never echoed or persisted.
    """
    password = _ssm().get_parameter(
        Name="/grafana/admin-password",
        WithDecryption=True,
    )["Parameter"]["Value"]
    env = os.environ.copy()
    env["GRAFANA_URL"] = "https://grafana.coilysiren.me"
    env["GRAFANA_AUTH"] = f"admin:{password}"
    if action == "init":
        run("terraform -chdir=terraform/grafana init", env=env)
        return
    run(f"terraform -chdir=terraform/grafana {action}", env=env)


def terraform_admin_kms(action: str = "plan"):
    """Run terraform against `terraform/admin-kms/`.

    No secret inputs - admin principal ARNs live in terraform.tfvars and
    are not sensitive. AWS creds come from the caller's shell.
    """
    if action == "init":
        run("terraform -chdir=terraform/admin-kms init")
        return
    run(f"terraform -chdir=terraform/admin-kms {action}")


def terraform_tailscale_oidc(action: str = "plan"):
    """Run terraform against `terraform/tailscale-oidc/`.

    Wires a Tailscale admin API key and a GitHub PAT into the provider env
    from SSM. Plaintext values are passed via env, never echoed or
    persisted. See docs/tailscale-oidc.md.
    """
    ssm = _ssm()
    # Admin OAuth client (all:write scope). The client itself is
    # long-lived; the provider auto-rotates the short-lived access tokens
    # it mints. Generated at:
    #   https://login.tailscale.com/admin/settings/trust-credentials
    # Separate from the runtime CI OAuth client at /tailscale/oauth-*
    # (devices/auth_keys only), which cannot manage ACLs or federated
    # identities.
    client_id = ssm.get_parameter(
        Name="/tailscale/admin/oauth-client-id",
        WithDecryption=True,
    )["Parameter"]["Value"]
    client_secret = ssm.get_parameter(
        Name="/tailscale/admin/oauth-client-secret",
        WithDecryption=True,
    )["Parameter"]["Value"]
    gh_token = ssm.get_parameter(
        Name="/github/pat",
        WithDecryption=True,
    )["Parameter"]["Value"]
    env = os.environ.copy()
    env["TAILSCALE_OAUTH_CLIENT_ID"] = client_id
    env["TAILSCALE_OAUTH_CLIENT_SECRET"] = client_secret
    env["GITHUB_TOKEN"] = gh_token
    if action == "init":
        run("terraform -chdir=terraform/tailscale-oidc init", env=env)
        return
    run(f"terraform -chdir=terraform/tailscale-oidc {action}", env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("cert-manager", help="Install or refresh cert-manager + ClusterIssuers.")

    p = sub.add_parser("aws-secrets", help="Bootstrap external-secrets + aws-credentials.")
    p.add_argument("--aws-access-key-id", required=True)
    p.add_argument("--aws-secret-access-key", required=True)

    sub.add_parser(
        "observability",
        help="Install or upgrade the VictoriaMetrics + Grafana stack.",
    )
    sub.add_parser(
        "observability-admin-password",
        help="Print the Grafana admin password.",
    )

    p = sub.add_parser(
        "terraform-grafana",
        help="Run terraform against terraform/grafana/ with GRAFANA_AUTH wired from SSM.",
    )
    p.add_argument("--action", default="plan", help="init / plan / apply / destroy.")

    p = sub.add_parser(
        "terraform-admin-kms",
        help="Run terraform against terraform/admin-kms/ (admin-only KMS key for SSM-wrapping).",
    )
    p.add_argument("--action", default="plan", help="init / plan / apply / destroy.")

    p = sub.add_parser(
        "terraform-tailscale-oidc",
        help="Run terraform against terraform/tailscale-oidc/ with TS admin OAuth + GH PAT wired from SSM.",
    )
    p.add_argument("--action", default="plan", help="init / plan / apply / destroy.")

    args = parser.parse_args()

    if args.cmd == "cert-manager":
        cert_manager()
    elif args.cmd == "aws-secrets":
        aws_secrets(args.aws_access_key_id, args.aws_secret_access_key)
    elif args.cmd == "observability":
        observability()
    elif args.cmd == "observability-admin-password":
        observability_admin_password()
    elif args.cmd == "terraform-grafana":
        terraform_grafana(args.action)
    elif args.cmd == "terraform-admin-kms":
        terraform_admin_kms(args.action)
    elif args.cmd == "terraform-tailscale-oidc":
        terraform_tailscale_oidc(args.action)


if __name__ == "__main__":
    main()
