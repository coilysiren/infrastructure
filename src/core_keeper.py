import invoke


@invoke.task
def tail(ctx: invoke.Context):
    ctx.run("journalctl -u core-keeper-server -f", echo=True)


@invoke.task
def restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart core-keeper-server", echo=True)


@invoke.task
def stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop core-keeper-server", echo=True)
    ctx.run("sudo systemctl disable core-keeper-server", echo=True)


@invoke.task
def start(ctx: invoke.Context):
    ctx.run("sudo systemctl start core-keeper-server", echo=True)
    ctx.run("sudo systemctl enable core-keeper-server", echo=True)


core_keeper_collection = invoke.Collection("core_keeper", tail, restart, stop, start)
