import invoke


@invoke.task
def core_keeper_tail(ctx: invoke.Context):
    ctx.run("journalctl -u core-keeper-server -f", echo=True)


@invoke.task
def core_keeper_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart core-keeper-server", echo=True)


@invoke.task
def core_keeper_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop core-keeper-server", echo=True)
    ctx.run("sudo systemctl disable core-keeper-server", echo=True)


@invoke.task
def core_keeper_start(ctx: invoke.Context):
    ctx.run("sudo systemctl start core-keeper-server", echo=True)
    ctx.run("sudo systemctl enable core-keeper-server", echo=True)
