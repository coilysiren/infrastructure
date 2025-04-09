import invoke


@invoke.task
def backend_restart(ctx: invoke.Context):
    ctx.run("sudo cp ./systemd/coilysiren-backend.service /etc/systemd/system/", echo=True)
    ctx.run("sudo systemctl daemon-reload", echo=True)
    ctx.run("sudo systemctl restart coilysiren-backend", echo=True)


@invoke.task
def backend_tail(ctx: invoke.Context):
    ctx.run("sudo journalctl -u coilysiren-backend -f", echo=True)


@invoke.task
def backend_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop coilysiren-backend", echo=True)
