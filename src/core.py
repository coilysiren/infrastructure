import os

import invoke


@invoke.task
def systemd_restart(ctx: invoke.Context):
    ctx.run("chmod +x ./scripts/*", echo=True)
    systemd_files = os.listdir("./systemd")

    for systemd_file in systemd_files:
        ctx.run(f"sudo cp ./systemd/{systemd_file} /etc/systemd/system/", echo=True)

    ctx.run("sudo systemctl daemon-reload", echo=True)

    for systemd_file in systemd_files:
        ctx.run(f"sudo systemctl enable {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl start {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl restart {systemd_file}", echo=True)


core_collection = invoke.Collection("core", systemd_restart)
