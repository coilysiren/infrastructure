#!/usr/bin/env python3

# builtin
import os
import textwrap

# 3rd party
import boto3
import invoke
import requests
import rcon


# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm")

# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sts.html#sts
sts = boto3.client("sts")

UBUNTU_VERSION = "22.04"

def get_ip_address(name: str):
    output = ec2.describe_instances(
        Filters=[
            {"Name": "tag:Name", "Values": [name]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    )
    ip_address = output["Reservations"][0]["Instances"][0]["PublicIpAddress"]
    return ip_address

@invoke.task
def ssh(
    ctx: invoke.Context,
    name="eco-server",
    user="ubuntu",
    cmd="bash",
    ssh_add="ssh-add ~/.ssh/aws.pem",
    connection_attempts=5,
    comment=False,
):
    ctx.run(ssh_add, echo=False)
    ip_address = get_ip_address(name)
    if comment:
        print("")
        print("\tRun the following command to ssh into the server:")
        print(f"\tssh -o 'ConnectionAttempts {connection_attempts}' -t {user}@{ip_address} '{cmd}'")
        print("")
    else:
        ctx.run(
            f"ssh -o 'ConnectionAttempts {connection_attempts}' -t {user}@{ip_address} '{cmd}'",
            pty=True,
            echo=True,
        )

@invoke.task
def scp(
    ctx: invoke.Context,
    name="eco-server",
    user="ubuntu",
    source="",
    destination="",
):
    source = source if source else os.path.join(os.getcwd(), "configs/")
    destination = destination if destination else "/home/ubuntu/games/"
    ip_address = get_ip_address(name)
    ctx.run(
        f"scp -r {source} {user}@{ip_address}:{destination}",
        pty=True,
        echo=True,
    )

@invoke.task
def tail(
    ctx: invoke.Context,
    name="eco-server",
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
                --stack-name game-server-iam \
                --no-fail-on-empty-changeset
            """
        ),
        pty=True,
        echo=True,
    )

    vpc = ec2.describe_vpcs()["Vpcs"][0]["VpcId"]
    home_ip = requests.get("http://ifconfig.me", timeout=5).text
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/security-groups.yaml && \
            aws cloudformation deploy \
                --template-file templates/security-groups.yaml \
                --parameter-overrides \
                    HomeIP='{home_ip}/32' \
                    VPC={vpc} \
                --stack-name game-server-security-groups \
                --no-fail-on-empty-changeset
            """
        ),
        pty=True,
        echo=True,
    )

@invoke.task
def build_image(ctx: invoke.Context, name="eco-server", env="dev"):
    account_id = sts.get_caller_identity()["Account"]

    ctx.run(
        f"""
        docker buildx build \
            --build-arg UBUNTU_VERSION={UBUNTU_VERSION} \
            --progress plain \
            --build-context scripts=scripts \
            --tag {account_id}.dkr.ecr.us-east-1.amazonaws.com/{name}-ecr:{env} \
            ./{name}/.
        """,
        pty=True,
        echo=True,
    )

    ctx.run(
        f"""
        aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin {account_id}.dkr.ecr.us-east-1.amazonaws.com
        """,
        pty=True,
        echo=True,
    )

    ctx.run(
        f"""
        docker push {account_id}.dkr.ecr.us-east-1.amazonaws.com/{name}-ecr:{env}
        """,
        pty=True,
        echo=True,
    )

@invoke.task
def build_ami(ctx: invoke.Context, env="dev"):
    ctx.run(
        "packer init ubuntu.pkr.hcl",
        pty=True,
        echo=True,
    )

    ctx.run(
        "packer fmt ubuntu.pkr.hcl",
        pty=True,
        echo=True,
    )

    ctx.run(
        f"packer validate -var ubuntu_version={UBUNTU_VERSION} -var env={env} ubuntu.pkr.hcl",
        pty=True,
        echo=True,
    )

    ctx.run(
        f"packer build -var ubuntu_version={UBUNTU_VERSION} -var env={env} ubuntu.pkr.hcl",
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
def deploy_assets(ctx: invoke.Context, name="eco-server"):
    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/ecr.yaml && \
            aws cloudformation deploy \
                --template-file templates/ecr.yaml \
                --stack-name {name}-ecr \
                --no-fail-on-empty-changeset
            """
        ),
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
                --stack-name {name}-dns \
                --no-fail-on-empty-changeset
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
                --stack-name {name}-volume \
                --no-fail-on-empty-changeset
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
                --stack-name {name} \
                --no-fail-on-empty-changeset
            """
        ),
        pty=True,
        echo=True,
    )

@invoke.task
def delete_server(ctx: invoke.Context, name="eco-server"):
    ip_address = get_ip_address(name)
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
def redeploy(ctx: invoke.Context, name="eco-server"):
    delete_server(ctx, name)
    deploy_shared(ctx)
    deploy_assets(ctx, name)
    deploy_server(ctx, name)

@invoke.task
def push_asset_local(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
    cd="",
):
    def cmd():
        ctx.run(
            f"aws s3 cp {download} s3://{bucket}/downloads/{download}",
            pty=True,
            echo=True,
        )

    if cd:
        with ctx.cd(cd):
            cmd()
    else:
        cmd()

@invoke.task
def push_asset_remote(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
):
    ssh(
        ctx,
        cmd=f"aws s3 cp /home/ubuntu/games/{download} s3://{bucket}/downloads/",
    )

@invoke.task
def pull_asset_remote(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
    name="eco-server",
    cd="",
):
    if cd:
        ssh(
            ctx,
            name=name,
            cmd=f"cd {cd} && aws s3 cp s3://{bucket}/downloads/{download} .",
        )
    else:
        ssh(
            ctx,
            name=name,
            cmd=f"aws s3 cp s3://{bucket}/downloads/{download} /home/ubuntu/games/",
        )

@invoke.task
def pull_asset_local(
    ctx: invoke.Context,
    download,
    bucket="coilysiren-assets",
):
    ctx.run(
        f"aws s3 cp s3://{bucket}/downloads/{download} ~/Downloads/",
        pty=True,
        echo=True,
    )

@invoke.task
def reboot(ctx: invoke.Context, name="eco-server"):
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
    name="eco-server",
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
    name="eco-server",
):
    ssh(
        ctx,
        name=name,
        cmd="rm -rf /home/ubuntu/games/terraria-logs/*",
    )


####################
# ECO SERVER STUFF #
####################

def eco_rcon(args: list[str]):
    ip_address = get_ip_address("eco-server")
    with rcon.source.Client(ip_address, 3002, passwd=os.getenv("RCONPASSWORD")) as client:
        response = client.run(*args)
    print(response)

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
def eco_announce(
    ctx: invoke.Context,
    msg: str,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "announce", msg])

@invoke.task
def eco_alert(
    ctx: invoke.Context,
    msg: str,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "alert", msg])

@invoke.task
def eco_players(
    ctx: invoke.Context,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "players"])

@invoke.task
def eco_listusers(
    ctx: invoke.Context,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listusers"])

@invoke.task
def eco_listadmins(
    ctx: invoke.Context,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listadmins"])

@invoke.task
def eco_save(
    ctx: invoke.Context,
):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "save"])
