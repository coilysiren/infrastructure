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


k8s_collection = invoke.Collection(
    "k8s",
    cert_manager,
    service_status,
    service_restart,
    service_stop,
    service_start,
    aws_secrets,
)
