#!/usr/bin/env python3

# builtin
import json
import os
import shutil
import stat
import textwrap

# 3rd party
import boto3
import invoke


# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2", region_name="us-east-1")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm", region_name="us-east-1")

# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sts.html#sts
sts = boto3.client("sts")

# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/route53.html#route53
route53 = boto3.client("route53")

USERNAME = os.getenv("USERNAME", "")

LINUX_SERVER_PATH = os.path.join(
    "/home",
    "kai",
    ".local",
    "share",
    "Steam",
    "steamapps",
    "common",
    "Eco",
    "Eco_Data",
    "Server",
)
WINDOWS_SERVER_PATH = os.path.join(
    "C:\\",
    "Program Files (x86)",
    "Steam",
    "steamapps",
    "common",
    "Eco",
    "Eco_Data",
    "Server",
)


def server_path():
    if "windows" in os.getenv("OS").lower():
        return WINDOWS_SERVER_PATH
    elif "linux" in os.getenv("OSTYPE").lower():
        return LINUX_SERVER_PATH
    else:
        raise Exception("Unsupported OS")


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
                    os.path.join(root, file),
                    os.path.relpath(os.path.join(root, file), os.path.join(path, "..")),
                )


def copy_paths(origin_path, target_path):
    if not os.path.isdir(origin_path):
        return
    if os.path.exists(target_path) and os.path.isdir(target_path):
        print(f"\tRemoving {target_path}")
        shutil.rmtree(target_path, ignore_errors=False, onerror=handleRemoveReadonly)
    if os.path.isdir(origin_path):
        print(f"\tCopying {origin_path} to {target_path}")
        shutil.copytree(origin_path, target_path)


def copy_mods():
    print("Copying mods to server")
    mods = os.listdir("./eco-server/mods/Mods")
    for mod in mods:
        origin_path = os.path.join("./eco-server/mods/Mods", mod)
        target_path = os.path.join(server_path(), "Mods", mod)
        if mod.endswith("UserCode"):
            continue
        copy_paths(origin_path, target_path)

    print("Copying user code mods to server")
    mods = os.listdir("./eco-server/mods/Mods/UserCode")
    for mod in mods:
        origin_path = os.path.join("./eco-server/mods/Mods/UserCode", mod)
        target_path = os.path.join(server_path(), "Mods", "UserCode", mod)
        copy_paths(origin_path, target_path)

    # TODO: handle overrides in UserCode/Tools/, UserCode/Objects/, etc
    # TODO: get the list of overrides by looking inside __core__

    if os.path.exists("./eco-server/mods/Configs"):
        print("Copying mod configs to server")
        shutil.copytree(
            "./eco-server/mods/Configs",
            os.path.join(server_path(), "Configs"),
            dirs_exist_ok=True,
        )


@invoke.task
def update_dns(ctx: invoke.Context):
    ip_address = ctx.run("curl -4 ifconfig.co", echo=True).stdout.strip()
    response = route53.list_hosted_zones_by_name(DNSName="coilysiren.me")
    hosted_zone = response["HostedZones"][0]["Id"].split("/")[-1]
    response = route53.change_resource_record_sets(
        HostedZoneId=hosted_zone,
        ChangeBatch={
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": "eco.coilysiren.me",
                        "Type": "A",
                        "TTL": 60,
                        "ResourceRecords": [
                            {"Value": ip_address},
                        ],
                    },
                },
            ],
        },
    )


@invoke.task
def copy_configs(ctx: invoke.Context):
    # Clean out configs folder
    print("Cleaning out configs folder")
    if os.path.exists("./eco-server/configs"):
        shutil.rmtree("./eco-server/configs", ignore_errors=False, onerror=handleRemoveReadonly)

    # Get configs from git
    ctx.run(
        "git clone --depth 1 git@github.com:coilysiren/eco-configs.git ./eco-server/configs",
        echo=True,
    )

    # Copy configs to server
    print("Copying configs to server")
    configs = os.listdir("./eco-server/configs/Configs")
    for config in configs:
        if config.split(".")[-1] != "template":
            config_path = os.path.join(server_path(), "Configs", config)
            if os.path.exists(config_path):
                os.remove(config_path)
            print(f"\tCopying ./eco-server/configs/Configs/{config} to {config_path}")
            shutil.copyfile(f"./eco-server/configs/Configs/{config}", config_path)


@invoke.task
def copy_private_mods(ctx: invoke.Context, branch="", local=False):
    print("Cleaning out mods folder")
    if os.path.exists("./eco-server/mods"):
        shutil.rmtree("./eco-server/mods", ignore_errors=False, onerror=handleRemoveReadonly)

    # get mods from git
    branch_flag = ""
    if branch != "":
        branch_flag = f"-b {branch}"
    ctx.run(
        f"git clone --depth 1 {branch_flag} -- git@github.com:coilysiren/eco-mods.git ./eco-server/mods",
        echo=True,
    )
    shutil.rmtree("./eco-server/mods/.git", ignore_errors=False, onerror=handleRemoveReadonly)

    if local:
        copy_mods()


@invoke.task
def copy_public_mods(ctx: invoke.Context, branch="", local=False):
    print("Cleaning out mods folder")
    if os.path.exists("./eco-server/mods"):
        shutil.rmtree("./eco-server/mods", ignore_errors=False, onerror=handleRemoveReadonly)

    # get mods from git
    branch_flag = ""
    if branch != "":
        branch_flag = f"-b {branch}"
    ctx.run(
        f"git clone --depth 1 {branch_flag} -- git@github.com:coilysiren/eco-mods-public.git ./eco-server/mods",
        echo=True,
    )
    shutil.rmtree("./eco-server/mods/.git", ignore_errors=False, onerror=handleRemoveReadonly)

    if local:
        copy_mods()


@invoke.task
def copy_assets(ctx: invoke.Context, branch=""):
    print("Cleaning out assets folder")
    if os.path.exists("./eco-server/assets"):
        shutil.rmtree("./eco-server/assets", ignore_errors=False, onerror=handleRemoveReadonly)

    # get assets from git
    branch_flag = ""
    if branch != "":
        branch_flag = f"-b {branch}"
    ctx.run(
        f"git clone --depth 1 {branch_flag} -- git@github.com:coilysiren/eco-mods-assets.git ./eco-server/assets",
        echo=True,
    )
    shutil.rmtree("./eco-server/assets/.git", ignore_errors=False, onerror=handleRemoveReadonly)

    for build in os.listdir("./eco-server/assets/Builds/Mods/UserCode/"):
        origin_path = os.path.join("./eco-server/assets/Builds/Mods/UserCode", build, "Assets")
        target_path = os.path.join(server_path(), "Mods", "UserCode", build, "Assets")
        copy_paths(origin_path, target_path)


@invoke.task
def run_private(ctx: invoke.Context):
    print("Modifying network.eco to reflect private server")
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "r", encoding="utf-8") as file:
        network = json.load(file)
        network["PublicServer"] = False
        network["Name"] = "localhost"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "localhost:3000"
        network["WebServerUrl"] = "http://localhost:3001"
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(network, file, indent=4)

    # get API key
    print("Getting API key")
    response = ssm.get_parameter(
        Name="/eco/server-api-token",
        WithDecryption=True,
    )
    eco_server_api_token = response["Parameter"]["Value"].strip()

    # run server
    os.chdir(server_path())
    ctx.run(f"EcoServer.exe -userToken={eco_server_api_token}", echo=True)


@invoke.task
def run_public(ctx: invoke.Context):
    print("Copying configs and mods to server to ensure they are up to date")
    copy_configs(ctx)
    copy_private_mods(ctx)
    copy_public_mods(ctx)

    print("Modifying network.eco to reflect public server")
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "r", encoding="utf-8") as file:
        network = json.load(file)
        network["PublicServer"] = True
        network["Name"] = "<color=green>Eco</color> <color=blue>Sirens</color>"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "eco.coilysiren.me:3000"
        network["WebServerUrl"] = "http://eco.coilysiren.me:3001"
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(network, file, indent=4)

    # This should be the default state, but we perform the modification just in case
    print("Modifying difficulty.eco to ensure static world")
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = False
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

    # get API key
    print("Getting API key")
    response = ssm.get_parameter(
        Name="/eco/server-api-token",
        WithDecryption=True,
    )
    eco_server_api_token = response["Parameter"]["Value"].strip()

    # run server
    os.chdir(server_path())
    ctx.run(f"EcoServer.exe -userToken={eco_server_api_token}", echo=True)


@invoke.task
def regenerate_world(ctx: invoke.Context):
    if os.path.exists(os.path.join(server_path(), "Storage")):
        shutil.rmtree(
            os.path.join(server_path(), "Storage"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )
    if os.path.exists(os.path.join(server_path(), "Logs")):
        shutil.rmtree(
            os.path.join(server_path(), "Logs"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )

    print("Modifying difficulty.eco to regenerate world")
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = True
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

    # Run the world generation
    run_private(ctx)


###################################################################


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
def deploy_server(ctx: invoke.Context, env="dev", name="eco-server"):
    dns_name = name.split("-")[0]
    env_suffix = "-dev" if env == "dev" else ""

    ctx.run(
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/dns.yaml && \
            aws cloudformation deploy \
                --template-file templates/dns.yaml \
                --parameter-overrides \
                    Name={name} \
                    Env={env} \
                    DnsName={dns_name}{env_suffix} \
                --stack-name {name}-{env}-dns \
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
                    Name={name}-{env} \
                --stack-name {name}-{env}-volume \
                --no-fail-on-empty-changeset
            """
        ),
        pty=True,
        echo=True,
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
        Name=f"/cfn/{name}-{env}/ebs-vol",
        WithDecryption=True,
    )
    ebs_volume = response["Parameter"]["Value"]

    # get EIP id
    response = ssm.get_parameter(
        Name=f"/cfn/{name}-{env}/eip-id",
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
        textwrap.dedent(
            f"""
            aws cloudformation validate-template --template-body file://templates/instance.yaml && \
            aws cloudformation deploy \
                --template-file templates/instance.yaml \
                --parameter-overrides \
                    Name={name}-{env} \
                    Service={name} \
                    Volume={ebs_volume} \
                    Env={env} \
                    AMI={ubuntu_ami} \
                    EIPAllocationId={eip_ip} \
                    SecurityGroups={",".join(security_groups)} \
                    InstanceType={InstanceType} \
                --stack-name {name}-{env}-instance \
                --no-fail-on-empty-changeset
            """
        ),
        pty=True,
        echo=True,
    )


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


####################
# ECO SERVER STUFF #
####################


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
