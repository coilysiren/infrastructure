#!/usr/bin/env python3

# builtin
import json
import os
import shutil
import stat
import uuid
import zipfile

# 3rd party
import boto3
import invoke
import jinja2


# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ec2.html
ec2 = boto3.client("ec2", region_name="us-east-1")

# docs: https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/ssm.html
ssm = boto3.client("ssm", region_name="us-east-1")

# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/sts.html#sts
sts = boto3.client("sts")

# https://boto3.amazonaws.com/v1/documentation/api/latest/reference/services/route53.html#route53
route53 = boto3.client("route53")

USERNAME = os.getenv("USERNAME", "")
SERVER_PATH = os.path.join(
    "C:\\",
    "Program Files (x86)",
    "Steam",
    "steamapps",
    "common",
    "Eco",
    "Eco_Data",
    "Server",
)
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
                    os.path.join(root, file),
                    os.path.relpath(os.path.join(root, file), os.path.join(path, "..")),
                )


def copy_paths(origin_path, target_path, in_place=False):
    if not os.path.isdir(origin_path):
        return
    if os.path.exists(target_path) and os.path.isdir(target_path) and in_place is False:
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
        target_path = os.path.join(SERVER_PATH, "Mods", mod)
        if mod.endswith("UserCode"):
            continue
        copy_paths(origin_path, target_path)

    print("Copying user code mods to server")
    mods = os.listdir("./eco-server/mods/Mods/UserCode")
    for mod in mods:
        origin_path = os.path.join("./eco-server/mods/Mods/UserCode", mod)
        target_path = os.path.join(SERVER_PATH, "Mods", "UserCode", mod)
        copy_paths(origin_path, target_path)

    # TODO: handle overrides in UserCode/Tools/, UserCode/Objects/, etc
    # TODO: get the list of overrides by looking inside __core__

    if os.path.exists("./eco-server/mods/Configs"):
        print("Copying mod configs to server")
        shutil.copytree(
            "./eco-server/mods/Configs",
            os.path.join(SERVER_PATH, "Configs"),
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
            config_path = os.path.join(SERVER_PATH, "Configs", config)
            if os.path.exists(config_path):
                os.remove(config_path)
            print(f"\tCopying ./eco-server/configs/Configs/{config} to {config_path}")
            shutil.copyfile(f"./eco-server/configs/Configs/{config}", config_path)


@invoke.task
def copy_private_mods(ctx: invoke.Context, branch=""):
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

    copy_mods()


@invoke.task
def copy_public_mods(ctx: invoke.Context, branch=""):
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

    copy_mods()


@invoke.task
def copy_assets(ctx: invoke.Context, branch="", in_place=False):
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
        target_path = os.path.join(SERVER_PATH, "Mods", "UserCode", build, "Assets")
        copy_paths(origin_path, target_path, in_place)


@invoke.task
def run_private(ctx: invoke.Context):
    print("Modifying network.eco to reflect private server")
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "r", encoding="utf-8") as file:
        network = json.load(file)
        network["PublicServer"] = False
        network["Name"] = "localhost"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "localhost:3000"
        network["WebServerUrl"] = "http://localhost:3001"
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(network, file, indent=4)

    # This should be the default state, but we perform the modification just in case
    print("Modifying difficulty.eco to ensure static world")
    with open(os.path.join(SERVER_PATH, "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = False
    with open(os.path.join(SERVER_PATH, "Configs", "Difficulty.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

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
def run_public(ctx: invoke.Context):
    print("Copying configs and mods to server to ensure they are up to date")
    copy_configs(ctx)
    copy_private_mods(ctx)
    copy_public_mods(ctx)

    print("Modifying network.eco to reflect public server")
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "r", encoding="utf-8") as file:
        network = json.load(file)
        network["PublicServer"] = True
        network["Name"] = "Eco Sirens"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "eco.coilysiren.me:3000"
        network["WebServerUrl"] = "http://eco.coilysiren.me:3001"
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(network, file, indent=4)

    # This should be the default state, but we perform the modification just in case
    print("Modifying difficulty.eco to ensure static world")
    with open(os.path.join(SERVER_PATH, "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = False
    with open(os.path.join(SERVER_PATH, "Configs", "Difficulty.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

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
def regenerate_world(ctx: invoke.Context):
    if os.path.exists(os.path.join(SERVER_PATH, "Storage")):
        shutil.rmtree(
            os.path.join(SERVER_PATH, "Storage"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )
    if os.path.exists(os.path.join(SERVER_PATH, "Logs")):
        shutil.rmtree(
            os.path.join(SERVER_PATH, "Logs"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )

    print("Modifying difficulty.eco to regenerate world")
    with open(os.path.join(SERVER_PATH, "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = True
    with open(os.path.join(SERVER_PATH, "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

    # Run the world generation
    run_private(ctx)
