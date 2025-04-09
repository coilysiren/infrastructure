import os

import invoke

from src.corekeeper import *
from src.eco import *


@invoke.task
def copy_systemd(ctx: invoke.Context):
    ctx.run("chmod +x ./scripts/*", echo=True)
    systemd_files = os.listdir("./systemd")
    for systemd_file in systemd_files:
        ctx.run(f"sudo cp ./systemd/{systemd_file} /etc/systemd/system/", echo=True)
        ctx.run(f"sudo systemctl enable {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl start {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl restart {systemd_file}", echo=True)


@invoke.task
def restart_caddy(ctx: invoke.Context):
    ctx.run("sudo cp ./caddy/Caddyfile /etc/caddy/Caddyfile", echo=True)
    ctx.run("sudo systemctl restart caddy", echo=True)
