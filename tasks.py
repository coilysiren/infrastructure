#!/usr/bin/env python3

# builtin
import os
import textwrap

# 3rd party
import boto3
import invoke
import requests


# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm")


@invoke.task
def ssh(
    ctx: invoke.Context,
    name="terraria-server",
    user="ubuntu",
    cmd="cd games/ && bash",
    connection_attempts=5,
):
    output = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    ip_address = output["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    ctx.run(
        f"ssh -o 'ConnectionAttempts {connection_attempts}' -t {user}@{ip_address} '{cmd}'",
        pty=True,
        echo=True,
    )


@invoke.task
def scp(
    ctx: invoke.Context,
    name="terraria-server",
    user="ubuntu",
    source="",
    destination="",
):
    source = source if source else os.path.join(os.getcwd(), "configs/")
    destination = destination if destination else "/home/ubuntu/games/"
    output = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    ip_address = output["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    ctx.run(
        f"scp -r {source}/* {user}@{ip_address}:{destination}",
        pty=True,
        echo=True,
    )


@invoke.task
def tail(
    ctx: invoke.Context,
    name="terraria-server",
):
    ssh(
        ctx,
        name=name,
        cmd='sudo multitail -c -ts -Q 1 "/var/log/*"',
    )


@invoke.task
def deploy_shared(ctx: invoke.Context):
    ctx.run(
        textwrap.dedent(
            """
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
    home_ip = requests.get("http://ifconfig.me").text
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
def deploy_apex_dns(ctx: invoke.Context):
    ctx.run(
        textwrap.dedent(
            """
            aws cloudformation validate-template --template-body file://templates/apex-dns.yaml && \
            aws cloudformation deploy \
                --template-file templates/apex-dns.yaml \
                --stack-name apex-dns
            """
        ),
        pty=True,
        echo=True,
    )


@invoke.task
def deploy_server(ctx: invoke.Context, name="terraria-server"):
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
def delete_server(ctx: invoke.Context, name="terraria-server"):
    output = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    ip_address = output["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    # reload ssh key - required until I figured out ssh identity pinning
    ctx.run(
        f"ssh-keygen -R {ip_address}",
        pty=True,
        echo=True,
    )
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
def redeploy(ctx: invoke.Context, name="terraria-server"):
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
        raise Exception(f'found too many downloads called "{download}" from {options}')

    asset_path = os.path.join(os.path.expanduser("~"), "Downloads", options[0])

    ctx.run(
        f"aws s3 cp {asset_path} s3://{bucket}/downloads/{download}",
        pty=True,
        echo=True,
    )


@invoke.task
def pull_asset(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
    name="terraria-server",
):
    ssh(
        ctx,
        name=name,
        cmd=f"aws s3 cp s3://{bucket}/downloads/{download} /home/ubuntu/games/",
    )


@invoke.task
def reboot(ctx: invoke.Context, name="terraria-server"):
    ssh(
        ctx,
        name=name,
        cmd="sudo reboot",
    )
    ssh(
        ctx,
        name=name,
    )


#########################
# TERRARIA SERVER STUFF #
#########################


@invoke.task
def terraria_push_code(
    ctx: invoke.Context,
    name="terraria-server",
):
    ssh(
        ctx,
        name=name,
        cmd="aws s3 cp s3://coilysiren-assets/downloads/terraria-server /home/ubuntu/games/",
    )
    ssh(
        ctx,
        name=name,
        cmd="cd /home/ubuntu/games/ && unzip -qq -u terraria-server",
    )
    ssh(
        ctx,
        name=name,
        cmd="cd /home/ubuntu/games/ && mv terraria-server-*/Linux/* terraria",
    )
    ssh(
        ctx,
        name=name,
        cmd="chmod a+x /home/ubuntu/games/terraria/TerrariaServer",
    )
    reboot(ctx, name=name)
    ssh(ctx, name=name, connection_attempts=60)


@invoke.task
def terraria_clean_logs(
    ctx: invoke.Context,
    name="terraria-server",
):
    ssh(
        ctx,
        name=name,
        cmd="rm -rf /home/ubuntu/games/terraria-logs/*",
    )


####################
# ECO SERVER STUFF #
####################


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
