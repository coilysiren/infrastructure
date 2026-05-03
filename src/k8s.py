import invoke
import boto3


CERT_MANAGER_VERSION = "v1.12.16"


ssm = boto3.client("ssm", region_name="us-east-1")


@invoke.task
def service_status(ctx: invoke.Context):
    ctx.run("sudo journalctl -xeu k3s.service")


@invoke.task
def service_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart k3s.service", echo=True)


@invoke.task
def service_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl disable k3s.service", echo=True)
    ctx.run("sudo systemctl stop k3s.service", echo=True)


@invoke.task
def service_start(ctx: invoke.Context):
    ctx.run("sudo systemctl enable k3s.service", echo=True)
    ctx.run("sudo systemctl start k3s.service", echo=True)


@invoke.task
def cert_manager(ctx: invoke.Context):
    ctx.run(
        f"kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/"
        f"{CERT_MANAGER_VERSION}/cert-manager.yaml",
        echo=True,
    )
    ctx.run("kubectl apply -f deploy/cert_manager.yml", echo=True)


@invoke.task
def aws_secrets(ctx: invoke.Context, aws_access_key_id: str, aws_secret_access_key: str):
    ctx.run("helm repo add external-secrets https://charts.external-secrets.io", echo=True)
    ctx.run("helm repo update", echo=True)
    ctx.run("kubectl create namespace external-secrets", echo=True, warn=True)
    ctx.run(
        "helm install external-secrets external-secrets/external-secrets "
        "--namespace external-secrets",
        echo=True,
        warn=True,
    )
    # Delete existing secret if it exists
    ctx.run(
        "kubectl delete secret aws-credentials -n external-secrets --ignore-not-found",
        echo=True,
        warn=True,
    )
    ctx.run(
        f"""kubectl create secret generic aws-credentials \
            --namespace external-secrets \
            --from-literal=aws_access_key_id={aws_access_key_id} \
            --from-literal=aws_secret_access_key={aws_secret_access_key}
        """,
        warn=True,
    )
    # Apply the SecretStore and ExternalSecret configurations
    ctx.run("kubectl apply -f deploy/secretstore.yml", echo=True)
    ctx.run("kubectl apply -f deploy/externalsecret.yml", echo=True)
    ctx.run("kubectl rollout restart deployment external-secrets -n external-secrets", echo=True)


@invoke.task
def observability(ctx: invoke.Context):
    """Install or upgrade the VictoriaMetrics + Grafana stack in the
    `observability` namespace. Idempotent; safe to re-run.

    See deploy/observability/README.md for the full design.
    """
    ctx.run("helm repo add vm https://victoriametrics.github.io/helm-charts/", echo=True, warn=True)
    ctx.run(
        "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts",
        echo=True,
        warn=True,
    )
    # The old grafana/helm-charts repo deprecated the grafana chart on
    # 2026-01-30 and pointed users at grafana-community/helm-charts. Same
    # maintainers, same values schema, drop-in replacement.
    ctx.run(
        "helm repo add grafana-community https://grafana-community.github.io/helm-charts",
        echo=True,
        warn=True,
    )
    ctx.run("helm repo update", echo=True)

    ctx.run("kubectl apply -f deploy/observability/namespace.yml", echo=True)
    # Sync admin password from SSM /grafana/admin-password into a k8s
    # Secret before grafana renders, so the chart can mount it via
    # admin.existingSecret without a chicken-and-egg.
    ctx.run(
        "kubectl apply -f deploy/observability/admin-password-externalsecret.yml",
        echo=True,
    )

    ctx.run(
        "helm upgrade --install node-exporter prometheus-community/prometheus-node-exporter "
        "--namespace observability "
        "-f deploy/observability/node-exporter-values.yml",
        echo=True,
    )
    ctx.run(
        "helm upgrade --install victoria-metrics vm/victoria-metrics-single "
        "--namespace observability "
        "-f deploy/observability/victoria-metrics-values.yml",
        echo=True,
    )
    # vmagent ships as a standalone chart, not bundled with vmsingle.
    ctx.run(
        "helm upgrade --install vmagent vm/victoria-metrics-agent "
        "--namespace observability "
        "-f deploy/observability/vmagent-values.yml",
        echo=True,
    )
    ctx.run(
        "helm upgrade --install grafana grafana-community/grafana "
        "--namespace observability "
        "-f deploy/observability/grafana-values.yml",
        echo=True,
    )


@invoke.task
def observability_admin_password(ctx: invoke.Context):
    """Print the auto-generated Grafana admin password."""
    ctx.run(
        "kubectl get secret -n observability grafana "
        "-o jsonpath='{.data.admin-password}' | base64 -d",
        echo=True,
    )


@invoke.task(help={"action": "terraform subcommand: init, plan, apply, destroy. Default: plan."})
def terraform_grafana(ctx: invoke.Context, action: str = "plan"):
    """Run terraform against `terraform/grafana/` to manage Grafana dashboards.

    Pulls the admin password from SSM (/grafana/admin-password) and exports
    GRAFANA_URL + GRAFANA_AUTH for the grafana provider. The plaintext
    password is passed to terraform via env, never echoed or persisted.
    """
    password = ssm.get_parameter(
        Name="/grafana/admin-password",
        WithDecryption=True,
    )["Parameter"]["Value"]
    env = {
        "GRAFANA_URL": "https://grafana.coilysiren.me",
        "GRAFANA_AUTH": f"admin:{password}",
    }
    if action == "init":
        ctx.run("terraform -chdir=terraform/grafana init", echo=True, env=env)
        return
    ctx.run(f"terraform -chdir=terraform/grafana {action}", echo=True, env=env)


k8s_collection = invoke.Collection(
    "k8s",
    cert_manager,
    service_status,
    service_restart,
    service_stop,
    service_start,
    aws_secrets,
    observability,
    observability_admin_password,
    terraform_grafana,
)
