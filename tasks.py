#!/usr/bin/env python3

# builtin
import json
import os
import shutil
import stat
import textwrap
import zipfile

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

USERNAME = os.getenv("USERNAME", "")
SERVER_PATH = os.path.join("C:\\", "Program Files (x86)", "Steam", "steamapps", "common", "Eco", "Eco_Data", "Server")
PROJECT_PATH = os.path.join("C:\\", "Users", USERNAME, "projects")


def handleRemoveReadonly(func, path, _):
    if not os.access(path, os.W_OK):
        os.chmod(path, stat.S_IWUSR)
        func(path)
    else:
        raise Exception("could not handle path")


def zipdir(path, ziph):
    print(f"Zipping {path}")
    for root, _, files in os.walk(path):
        for file in files:
            not_eco_zip = file.startswith("EcoServer.zip") is False
            not_logs = file.startswith(".\\Logs\\") is False
            not_storage = file.startswith(".\\Storage\\") is False
            if not_eco_zip and not_storage and not_logs:
                print("zipping", os.path.join(root, file))
                ziph.write(
                    os.path.join(root, file), os.path.relpath(os.path.join(root, file), os.path.join(path, ".."))
                )


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
def local_copy_configs(ctx: invoke.Context):
    # Clean out configs folder
    print("Cleaning out configs folder")
    if os.path.exists("./eco-server/configs"):
        shutil.rmtree("./eco-server/configs", ignore_errors=False, onerror=handleRemoveReadonly)

    # Get configs from git
    ctx.run("git clone --depth 1 git@github.com:coilysiren/eco-configs.git ./eco-server/configs", echo=True)

    # Copy configs to server
    print("Copying configs to server")
    configs = os.listdir("./eco-server/configs/Configs")
    for config in configs:
        if config.split(".")[-1] != "template":
            config_path = os.path.join(SERVER_PATH, "Configs", config)
            if os.path.exists(config_path):
                os.remove(config_path)
            print(f"\tCopying ./eco-server/configs/Configs/{config} to {config_path}")
            shutil.copyfile(f"./eco-server/configs/Configs/{config}", config_path)


@invoke.task
def local_copy_mods(ctx: invoke.Context):
    # clean out mods folder
    print("Cleaning out mods folder")
    if os.path.exists("./eco-server/mods"):
        shutil.rmtree("./eco-server/mods", ignore_errors=False, onerror=handleRemoveReadonly)

    # get mods from git
    ctx.run("git clone --depth 1 git@github.com:coilysiren/eco-mods.git ./eco-server/mods", echo=True)

    # copy mods to server
    print("Copying mods to server")
    mods = os.listdir("./eco-server/mods/Mods")
    for mod in mods:
        mod_path = os.path.join(SERVER_PATH, "Mods", mod)
        if os.path.exists(mod_path):
            shutil.rmtree(mod_path, ignore_errors=False, onerror=handleRemoveReadonly)
        print(f"\tCopying ./eco-server/mods/Mods/{mod} to {mod_path}")
        shutil.copytree(f"./eco-server/mods/Mods/{mod}", mod_path)


@invoke.task
def local_run(ctx: invoke.Context):
    local_copy_configs(ctx)
    local_copy_mods(ctx)

    # modify network.eco to reflect local server
    print("Modifying network.eco to reflect local server")
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "r", encoding="utf-8") as file:
        network = json.load(file)
        network["PublicServer"] = False
        network["Name"] = "localhost"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "localhost:3000"
        network["WebServerUrl"] = "http://localhost:3001"
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(network, file, indent=4)

    # get API key
    print("Getting API key")
    response = ssm.get_parameter(
        Name="/eco/server-api-token",
        WithDecryption=True,
    )
    eco_server_api_token = response["Parameter"]["Value"].strip()

    # run server
    os.chdir(SERVER_PATH)
    ctx.run(f"EcoServer.exe -userToken={eco_server_api_token}", echo=True)


@invoke.task
def local_zip(ctx: invoke.Context):
    # # get fresh configs and mods
    # local_copy_configs(ctx)
    # local_copy_mods(ctx)

    # zip server folder
    os.chdir(SERVER_PATH)
    if os.path.exists("EcoServer.zip"):
        os.remove("EcoServer.zip")
    with zipfile.ZipFile("EcoServer.zip", "w", zipfile.ZIP_DEFLATED) as zipf:
        zipdir(".", zipf)


@invoke.task
def build_ami(ctx: invoke.Context):
    ctx.run("packer init ubuntu.pkr.hcl")
    ctx.run("packer fmt ubuntu.pkr.hcl")
    ctx.run("packer validate ubuntu.pkr.hcl")
    ctx.run("packer build ubuntu.pkr.hcl")


@invoke.task
def deploy_apex_dns(ctx: invoke.Context):
    ctx.run(
        """
        aws cloudformation validate-template --template-body file://templates/apex-dns.yaml && \
        aws cloudformation deploy \
            --template-file templates/apex-dns.yaml \
            --stack-name apex-dns
        """
    )


@invoke.task
def deploy_server(ctx: invoke.Context, env="dev", name="eco-server"):
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
def delete_server(ctx: invoke.Context, env="dev", name="eco-server"):
    ip_address = get_ip_address(name=name)
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
def redeploy(ctx: invoke.Context, env="dev", name="eco-server"):
    delete_server(ctx, env=env, name=name)
    deploy_server(ctx, env=env, name=name)


@invoke.task
def reboot(ctx: invoke.Context, name="eco-server"):
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
    ssh(ctx, cmd='multitail -Q 1 "/home/ubuntu/games/eco/Logs/*"')


@invoke.task
def eco_restart(ctx: invoke.Context):
    ssh(ctx, cmd="sudo systemctl restart eco-server")


@invoke.task
def eco_announce(ctx: invoke.Context, msg: str):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "announce", msg])


@invoke.task
def eco_alert(ctx: invoke.Context, msg: str):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "alert", msg])


@invoke.task
def eco_players(ctx: invoke.Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "players"])


@invoke.task
def eco_listusers(ctx: invoke.Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listusers"])


@invoke.task
def eco_listadmins(ctx: invoke.Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "listadmins"])


@invoke.task
def eco_save(ctx: invoke.Context):
    # https://wiki.play.eco/en/Chat_Commands
    eco_rcon(["manage", "save"])
