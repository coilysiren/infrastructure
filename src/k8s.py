import json
import invoke
import jinja2

CERT_MANAGER_VERSION = "v1.12.16"


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
        f"kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/{CERT_MANAGER_VERSION}/cert-manager.yaml",
        echo=True,
    )
    ctx.run("kubectl apply -f deploy/cert_manager.yml", echo=True)


@invoke.task
def cert_manager_loopback_fix(ctx: invoke.Context):
    """
    This is a fix for clusters (like residential ones) that have a problem with accessing the loopback address
    for the ACME HTTP-01 challenge. Specifically what happens is that the challenge tries to run a self check
    to verify that the challenge URL has been hosted on the ingress. However, some residential networks block access
    to the loopback address, so the self check fails.

    To fix this this, we have to patch coredns and our cert manager deployment to:

      1. alias the DNS name of the domain we want to verify to the ingress's private IP address, via a coredns configmap
      2. remove the hostAliases from the cert manager deployment, which would otherwise override our coredns alias
    """

    ingresses = json.loads(ctx.run("kubectl get ingress --all-namespaces -o json", echo=True).stdout)

    loopbacks = {}

    for item in ingresses["items"]:
        for ingress in item["status"]["loadBalancer"]["ingress"]:
            if ip := ingress.get("ip"):
                for tls in item["spec"]["tls"]:
                    for host in tls["hosts"]:
                        loopbacks[host] = ip

    with open("deploy/coredns_jinja.yml", "r", encoding="utf-8") as f:
        template = jinja2.Template(f.read())

    with open("deploy/coredns_filled.yml", "w", encoding="utf-8") as f:
        f.write(template.render(loopbacks=loopbacks))

    ctx.run("kubectl apply -f deploy/coredns_filled.yml", echo=True)
    ctx.run("kubectl rollout restart deployment coredns -n kube-system", echo=True)
    ctx.run(
        """
        kubectl patch deployment cert-manager -n cert-manager --type=json -p='[{"op": "remove", "path": "/spec/template/spec/hostAliases"}]' --dry-run=server -o yaml
    """,
        echo=True,
        warn=True,
    )


k8s_collection = invoke.Collection(
    "k8s",
    cert_manager,
    cert_manager_loopback_fix,
    service_status,
    service_restart,
    service_stop,
    service_start,
)
