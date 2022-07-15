#!/usr/bin/env python3

# builtin
import inspect
import os
import textwrap
import unittest.mock

# 3rd party
import boto3
import invoke
import requests


def __fix_annotations():
    """
    Pyinvoke doesnt accept annotations by default, this fix that
    Based on: https://github.com/pyinvoke/invoke/pull/606

    via this comment:
    https://github.com/pyinvoke/invoke/issues/357#issuecomment-583851322
    """

    def patched_inspect_getargspec(func):
        spec = inspect.getfullargspec(func)
        return inspect.ArgSpec(*spec[0:4])

    org_task_argspec = invoke.tasks.Task.argspec

    def patched_task_argspec(*args, **kwargs):
        with unittest.mock.patch(
            target="inspect.getargspec", new=patched_inspect_getargspec
        ):
            return org_task_argspec(*args, **kwargs)

    invoke.tasks.Task.argspec = patched_task_argspec


__fix_annotations()

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm")


@invoke.task
def ssh(ctx: invoke.Context, name="eco-server", user="ubuntu", cmd="cd games/ && bash"):
    ctx.run(
        f"ssh  -o 'ConnectionAttempts 10' -t {user}@{name}.coilysiren.me '{cmd}'",
        pty=True,
        echo=True,
    )


@invoke.task
def deploy_shared(ctx: invoke.Context):
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/iam.yaml && \
            aws cloudformation deploy \
                --template-file templates/iam.yaml \
                --capabilities CAPABILITY_NAMED_IAM \
                --stack-name game-server-iam
            """
        ),
        pty=True,
        echo=True,
    )

    vpc = ec2.describe_vpcs()["Vpcs"][0]["VpcId"]
    home_ip = requests.get("http://ifconfig.me").text  # TODO: ssm /cfn/home-ip-address
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/security-groups.yaml && \
            aws cloudformation deploy \
                --template-file templates/security-groups.yaml \
                --parameter-overrides \
                    HomeIP='{home_ip}/32' \
                    VPC={vpc} \
                --stack-name game-server-security-groups
            """
        ),
        pty=True,
        echo=True,
    )


@invoke.task
def build(ctx: invoke.Context):
    ctx.run(
        "shellcheck ./scripts/*",
        pty=True,
        echo=True,
    )

    ctx.run(
        "packer init .",
        pty=True,
        echo=True,
    )
    ctx.run(
        "packer fmt .",
        pty=True,
        echo=True,
    )
    ctx.run(
        "packer validate .",
        pty=True,
        echo=True,
    )

    deploy_shared(ctx)

    ctx.run(
        "packer build ubuntu.pkr.hcl",
        pty=True,
        echo=True,
    )


@invoke.task
def deploy_server(ctx: invoke.Context, name="eco-server"):
    deploy_shared(ctx)

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/dns.yaml && \
            aws cloudformation deploy \
                --template-file templates/dns.yaml \
                --parameter-overrides \
                    Name={name} \
                --stack-name {name}-dns
            """
        ),
        pty=True,
        echo=True,
    )

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/volume.yaml && \
            aws cloudformation deploy \
                --template-file templates/volume.yaml \
                --parameter-overrides \
                    Name={name} \
                --stack-name {name}-volume
            """
        ),
        pty=True,
        echo=True,
    )

    # get AMI
    response = ec2.describe_images(
        Filters=[
            {"Name": "name", "Values": ["ubuntu-packer"]},
        ],
    )
    ubuntu_ami = response["Images"][0]["ImageId"]

    # get EBS volume
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/ebs-vol",
        WithDecryption=True,
    )
    ebs_volume = response["Parameter"]["Value"]

    # get EIP id
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/eip-id",
        WithDecryption=True,
    )
    eip_ip = response["Parameter"]["Value"]

    # get security groups
    security_groups = []
    response = ssm.get_parameter(
        Name="/cfn/base-security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])
    response = ssm.get_parameter(
        Name=f"/cfn/{name}/security-group",
        WithDecryption=True,
    )
    security_groups.append(response["Parameter"]["Value"])

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/instance.yaml && \
            aws cloudformation deploy \
                --template-file templates/instance.yaml \
                --parameter-overrides \
                    Name={name} \
                    Volume={ebs_volume} \
                    AMI={ubuntu_ami} \
                    EIPAllocationId={eip_ip} \
                    SecurityGroups={",".join(security_groups)} \
                --stack-name {name}
            """
        ),
        pty=True,
        echo=True,
    )


@invoke.task
def delete_server(ctx: invoke.Context, name="eco-server"):
    ctx.run(
        f"aws cloudformation delete-stack --stack-name {name}",
        pty=True,
        echo=True,
    )
    ctx.run(
        f"aws cloudformation wait stack-delete-complete --stack-name {name}",
        pty=True,
        echo=True,
    )


@invoke.task
def redeploy(ctx: invoke.Context, name="eco-server"):
    delete_server(ctx, name)
    deploy_server(ctx, name)


@invoke.task
def push_asset(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
):
    downloads = os.listdir(os.path.join(os.path.expanduser("~"), "Downloads"))
    options = [filename for filename in downloads if download in filename]

    if len(options) == 0:
        raise Exception(f'could not find "{download}" download from {downloads}')
    elif len(options) > 1:
        raise Exception(
            f'found too many downloads called "{download}" from {downloads}'
        )

    asset_path = os.path.join(os.path.expanduser("~"), "Downloads", options[0])

    ctx.run(
        f"aws s3 cp {asset_path} s3://{bucket}/downloads/{download}",
        pty=True,
        echo=True,
    )


@invoke.task
def eco_push_mods(
    ctx: invoke.Context,
    bucket="coilysiren-assets",
):
    ctx.run(
        "rm -rf eco-mod-cache* && git clone git@github.com:coilysiren/eco-mod-cache.git",
        pty=True,
        echo=True,
    )
    ctx.run(
        "cd eco-mod-cache && zip -r eco-mod-cache * && cd -",
        pty=True,
        echo=True,
    )
    ctx.run(
        "mv eco-mod-cache/eco-mod-cache.zip ~/Downloads/",
        pty=True,
        echo=True,
    )
    push_asset(ctx, download="eco-mod-cache")
    ssh(
        ctx,
        cmd=f"cd /home/ubuntu/games/eco/Mods/UserCode && aws s3 cp s3://{bucket}/downloads/eco-mod-cache . && unzip -u -o eco-mod-cache",
    )
    eco_restart(ctx)
    eco_tail(ctx)


@invoke.task
def eco_push_config(
    ctx: invoke.Context,
    bucket="coilysiren-assets",
):
    ctx.run(
        "rm -rf eco-configs* && git clone git@github.com:coilysiren/eco-configs.git",
        pty=True,
        echo=True,
    )
    ctx.run(
        "cd eco-configs && zip -r eco-configs * && cd -",
        pty=True,
        echo=True,
    )
    ctx.run(
        "mv eco-configs/eco-configs.zip ~/Downloads/",
        pty=True,
        echo=True,
    )
    push_asset(ctx, download="eco-configs")
    ssh(
        ctx,
        cmd=f"cd /home/ubuntu/games/eco/Configs && aws s3 cp s3://{bucket}/downloads/eco-configs . && unzip -u -o eco-configs",
    )
    eco_restart(ctx)
    eco_tail(ctx)


@invoke.task
def eco_push_savefile(
    ctx: invoke.Context,
    bucket="coilysiren-assets",
):
    ctx.run(
        "rm -rf eco-savefile* && git clone git@github.com:coilysiren/eco-savefile.git",
        pty=True,
        echo=True,
    )
    ctx.run(
        "cd eco-savefile && zip -r eco-savefile * && cd -",
        pty=True,
        echo=True,
    )
    ctx.run(
        "mv eco-savefile/eco-savefile.zip ~/Downloads/",
        pty=True,
        echo=True,
    )
    push_asset(ctx, download="eco-savefile")
    ssh(
        ctx,
        cmd=f"cd /home/ubuntu/games/eco/Storage && aws s3 cp s3://{bucket}/downloads/eco-savefile . && unzip -u -o eco-savefile",
    )
    eco_restart(ctx)


@invoke.task
def eco_tail(
    ctx: invoke.Context,
):
    ssh(
        ctx,
        cmd='multitail -Q 1 "/home/ubuntu/games/eco/Logs/*"',
    )


@invoke.task
def eco_restart(
    ctx: invoke.Context,
):
    ssh(
        ctx,
        cmd="sudo systemctl restart eco-server",
    )


@invoke.task
def eco_reboot(
    ctx: invoke.Context,
):
    eco_restart(ctx)
    ssh(
        ctx,
        cmd="sudo reboot",
    )
