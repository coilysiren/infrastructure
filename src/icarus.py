import invoke


@invoke.task
def tail(ctx: invoke.Context):
    ctx.run("journalctl -u icarus-server -f", echo=True)


@invoke.task
def restart(ctx: invoke.Context):
    ctx.run("sudo systemctl daemon-reload", echo=True)
    ctx.run("sudo systemctl restart icarus-server", echo=True)


@invoke.task
def stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop icarus-server", echo=True)
    ctx.run("sudo systemctl disable icarus-server", echo=True)


@invoke.task
def start(ctx: invoke.Context):
    ctx.run("sudo systemctl start icarus-server", echo=True)
    ctx.run("sudo systemctl enable icarus-server", echo=True)


icarus_collection = invoke.Collection(
    "icarus",
    tail,
    restart,
    stop,
    start,
)
