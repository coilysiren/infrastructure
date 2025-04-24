import boto3
import invoke


ssm = boto3.client("ssm", region_name="us-east-1")


@invoke.task
def deploy_secrets_docker_repo(ctx: invoke.Context):
    github_token = ssm.get_parameter(
        Name="/github/pat",
        WithDecryption=True,
    )[
        "Parameter"
    ]["Value"]
    ctx.run("kubectl create namespace llama", echo=True, warn=True)
    ctx.run(
        f"echo {github_token} | docker login ghcr.io -u coilysiren/llama --password-stdin",
        echo=True,
    )
    ctx.run(
        f"""
        kubectl create secret docker-registry docker-registry \
            --namespace=llama \
            --docker-server=ghcr.io/coilysiren/llama \
            --docker-username=coilysiren/llama \
            --docker-password={github_token} \
            --dry-run=client -o yaml | kubectl apply -f -
        """,
        echo=True,
    )


@invoke.task
def deploy(ctx: invoke.Context):
    ctx.run("kubectl create namespace llama", echo=True, warn=True)
    ctx.run("kubectl apply -f llama/deploy.yml", echo=True)


llama_collection = invoke.Collection(
    "llama",
    deploy_secrets_docker_repo,
    deploy,
)
