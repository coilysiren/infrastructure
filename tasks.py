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

WINDOWS_USERNAME = "firem"

class Context(invoke.Context):
    def run(self, command):
        super().run(textwrap.dedent(command), echo=True, pty=True)

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
    ctx: Context,
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
    ctx: Context,
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
    ctx: Context,
    name="eco-server",
):
    ssh(
        ctx,
        name=name,
        cmd='sudo multitail -c -ts -Q 1 "/var/log/*"',
    )

@invoke.task
def deploy_shared(ctx: Context, name="eco-server"):
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
def local_copy_source(ctx: Context, redownload=False):
    ctx.run("rm -rf ./eco-server/source")
    ctx.run("mkdir ./eco-server/source")

    if redownload:
        ctx.run("rm -rf ./eco-server/source/EcoServerLinux.zip")
        ctx.run(f"rm -rf /mnt/c/Users/{WINDOWS_USERNAME}/Downloads/EcoServerLinux*.zip")
        input("Go download the Eco linux server from play.eco, then press enter to continue.")

    ctx.run(f"cp /mnt/c/Users/{WINDOWS_USERNAME}/Downloads/EcoServerLinux*.zip ./eco-server/source/EcoServerLinux.zip")
    ctx.run("unzip ./eco-server/source/EcoServerLinux.zip -d ./eco-server/source/")
    ctx.run("rm -rf ./eco-server/source/EcoServerLinux.zip")
    ctx.run("chmod +x ./eco-server/source/EcoServer")
    ctx.run("chmod +x ./eco-server/source/install.sh")

@invoke.task
def local_copy_mods(ctx: Context):
    ctx.run("rm -rf ./eco-server/mods")
    ctx.run("mkdir -p ./eco-server/mods")
    ctx.run("git clone --depth 1 git@github.com:coilysiren/eco-mods.git ./eco-server/mods")
    ctx.run("rm -rf ./eco-server/mods/.git")
    ctx.run("cp -r ./eco-server/mods/. ./eco-server/source/")

@invoke.task
def local_copy_configs(ctx: Context):
    ctx.run("rm -rf ./eco-server/configs")
    ctx.run("mkdir -p ./eco-server/configs/")
    ctx.run("git clone --depth 1 git@github.com:coilysiren/eco-configs.git ./eco-server/configs")
    ctx.run("rm -rf ./eco-server/configs/.git")
    ctx.run("cp -r ./eco-server/configs/. ./eco-server/source/")

@invoke.task
def local_copy(ctx: Context, redownload=False):
    local_copy_source(ctx, redownload=redownload)
    local_copy_mods(ctx)
    local_copy_configs(ctx)

@invoke.task
def local_run(ctx: Context):
    # TODO: rsync
    # TODO: modify network.eco for local runs
    response = ssm.get_parameter(
        Name="/eco/server-api-token",
        WithDecryption=True,
    )
    eco_server_api_token = response["Parameter"]["Value"].strip()
    with ctx.cd("./eco-server/source/"):
        ctx.run(f"./EcoServer -userToken=\"{eco_server_api_token}\"")

@invoke.task
def build_ami(ctx: Context):
    ctx.run("packer init ubuntu.pkr.hcl")
    ctx.run("packer fmt ubuntu.pkr.hcl")
    ctx.run("packer validate ubuntu.pkr.hcl")
    ctx.run(f"packer build ubuntu.pkr.hcl")

@invoke.task
def deploy_apex_dns(ctx: Context):
    ctx.run(
        """
        aws cloudformation validate-template --template-body file://templates/apex-dns.yaml && \
        aws cloudformation deploy \
            --template-file templates/apex-dns.yaml \
            --stack-name apex-dns
        """
    )

@invoke.task
def deploy_server(ctx: Context, env="dev", name="eco-server"):
    dns_name = name.split("-")[0]
    deploy_shared(ctx)
    ctx.run(
        f"""
        aws cloudformation validate-template --template-body file://templates/dns.yaml && \
        aws cloudformation deploy \
            --template-file templates/dns.yaml \
            --parameter-overrides \
                Name={name} \
                Env={env} \
                DnsName={dns_name} \
            --stack-name {name}-dns \
            --no-fail-on-empty-changeset
        """
    )
    ctx.run(
        f"""
        aws cloudformation validate-template --template-body file://templates/volume.yaml && \
        aws cloudformation deploy \
            --template-file templates/volume.yaml \
            --parameter-overrides \
                Name={name} \
            --stack-name {name}-volume \
            --no-fail-on-empty-changeset
        """
    )

    # get AMI
    response = ec2.describe_images(
        Filters=[
            {"Name": "name", "Values": [f"ubuntu-packer-{env}"]},
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

    if env == "dev":
        InstanceType = "t3.medium"
    else:
        InstanceType = "t3.large"

    ctx.run(
        f"""
        aws cloudformation validate-template --template-body file://templates/instance.yaml && \
        aws cloudformation deploy \
            --template-file templates/instance.yaml \
            --parameter-overrides \
                Name={name} \
                Service={name} \
                Volume={ebs_volume} \
                Env={env} \
                AMI={ubuntu_ami} \
                EIPAllocationId={eip_ip} \
                SecurityGroups={",".join(security_groups)} \
                InstanceType={InstanceType} \
            --stack-name {name}-instance \
            --no-fail-on-empty-changeset
        """
    )

@invoke.task
def delete_server(ctx: Context, env="dev", name="eco-server"):
    ip_address = get_ip_address(name=name, env=env)
    # reload ssh key - required until I figured out ssh identity pinning
    ctx.run(
        f"ssh-keygen -R {ip_address}",
        pty=True,
        echo=True,
    )
    ctx.run(
        f"aws cloudformation delete-stack --stack-name {name}-instance",
        pty=True,
        echo=True,
    )
    ctx.run(
        f"aws cloudformation wait stack-delete-complete --stack-name {name}-instance",
        pty=True,
        echo=True,
    )

@invoke.task
def redeploy(ctx: Context, env="dev", name="eco-server"):
    delete_server(ctx, env=env, name=name)
    deploy_server(ctx, env=env, name=name)

@invoke.task
def push_asset_local(
    ctx: Context,
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
    ctx: Context,
    download,
    bucket="coilysiren-assets",
):
    ssh(
        ctx,
        cmd=f"aws s3 cp /home/ubuntu/games/{download} s3://{bucket}/downloads/",
    )

@invoke.task
def pull_asset_remote(
    ctx: Context,
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
    ctx: Context,
    download,
    bucket="coilysiren-assets",
):
    ctx.run(
        f"aws s3 cp s3://{bucket}/downloads/{download} ~/Downloads/",
        pty=True,
        echo=True,
    )

@invoke.task
def reboot(ctx: Context, name="eco-server"):
    ssh(
        ctx,
        name=name,
        cmd="sudo reboot",
    )

#########################
# TERRARIA SERVER STUFF #
#########################

@invoke.task
def terraria_push_code(
    ctx: Context,
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
    ctx: Context,
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
    ctx: Context,
):
    ssh(ctx, cmd='multitail -Q 1 "/home/ubuntu/games/eco/Logs/*"')

@invoke.task
def eco_restart(ctx: Context):
    ssh(ctx, cmd="sudo systemctl restart eco-server")

@invoke.task
def eco_announce(ctx: Context, msg: str):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "announce", msg])

@invoke.task
def eco_alert(ctx: Context, msg: str):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "alert", msg])

@invoke.task
def eco_players(ctx: Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "players"])

@invoke.task
def eco_listusers(ctx: Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listusers"])

@invoke.task
def eco_listadmins(ctx: Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listadmins"])

@invoke.task
def eco_save(ctx: Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "save"])
