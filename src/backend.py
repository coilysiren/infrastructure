import invoke


@invoke.task
def backend_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart coilysiren-backend", echo=True)


@invoke.task
def backend_tail(ctx: invoke.Context):
    ctx.run("sudo journalctl -u coilysiren-backend -f", echo=True)
