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
def dns(ctx: invoke.Context):
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
    service_status,
    service_restart,
    service_stop,
    service_start,
    dns,
)
