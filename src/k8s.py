import invoke


CERT_MANAGER_VERSION = "v1.12.16"


@invoke.task
def deploy_cert_manager(ctx: invoke.Context):
    ctx.run(
        f"kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{CERT_MANAGER_VERSION}/cert-manager.yaml",
        echo=True,
    )


k8s_collection = invoke.Collection("k8s", deploy_cert_manager)
