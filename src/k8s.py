import invoke


CERT_MANAGER_VERSION = "v1.12.16"


@invoke.task
def k3s_service_status(ctx: invoke.Context):
    ctx.run("sudo journalctl -xeu k3s.service")


@invoke.task
def k3s_service_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart k3s.service", echo=True)


@invoke.task
def k3s_service_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop k3s.service", echo=True)


@invoke.task
def deploy_main(ctx: invoke.Context):
    ctx.run(
        "kubectl apply -f deploy/main.yml",
        echo=True,
    )


@invoke.task
def deploy_cert_manager(ctx: invoke.Context):
    ctx.run(
        f"kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{CERT_MANAGER_VERSION}/cert-manager.yaml",
        echo=True,
    )


@invoke.task
def deploy_api_coilysiren_me_cert(ctx: invoke.Context):
    ctx.run(
        "kubectl apply -f deploy/cert-api-coilysiren-me.yml",
        echo=True,
    )


@invoke.task
def deploy_coilysiren_me_cert(ctx: invoke.Context):
    ctx.run(
        "kubectl apply -f deploy/cert-coilysiren-me.yml",
        echo=True,
    )


k8s_collection = invoke.Collection(
    "k8s",
    deploy_main,
    deploy_cert_manager,
    deploy_api_coilysiren_me_cert,
    deploy_coilysiren_me_cert,
    k3s_service_status,
    k3s_service_restart,
    k3s_service_stop,
)
