#!/usr/bin/env python3

# builtin
import json
import os
import shutil
import stat

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


PUBLIC_MODS_FOLDER = os.path.join(os.path.expanduser("~"), "projects", "eco-mods-public")
PRIVATE_MODS_FOLDER = os.path.join(os.path.expanduser("~"), "projects", "eco-mods")

LINUX_SERVER_PATH = os.path.join(
    "/home",
    "kai",
    "Steam",
    "steamapps",
    "common",
    "EcoServer",
).replace("\\", "/")
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


def handleRemoveReadonly(func, path, _):
    if not os.access(path, os.W_OK):
        os.chmod(path, stat.S_IWUSR)
        func(path)
    else:
        raise Exception("could not handle path")


def eco_binary():
    if "windows" in os.getenv("OS", "").lower():
        return "EcoServer.exe"
    else:
        return "./EcoServer"


def server_path():
    if "windows" in os.getenv("OS", "").lower():
        return WINDOWS_SERVER_PATH
    else:
        return LINUX_SERVER_PATH


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


def symlink_mods(mods_folder, mod):
    full_source_path = os.path.join(mods_folder, "Mods", "UserCode", mod)
    full_target_path = os.path.join(server_path(), "Mods", "UserCode", mod)

    if not os.path.exists(full_source_path):
        raise FileNotFoundError(f"{full_source_path} does not exist")

    if os.path.isdir(full_target_path):
        print("Removing existing mod folder")
        shutil.rmtree(
            full_target_path,
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )

    _symlink_mods(mods_folder, os.path.join("Mods", "UserCode", mod))


def _symlink_mods(mods_folder, path):
    for file in os.listdir(os.path.join(mods_folder, path)):

        if os.path.isdir(os.path.join(path, file)):
            _symlink_mods(mods_folder, os.path.join(path, file))

        elif file.endswith(".cs") or file.endswith(".unity3d"):

            source = os.path.join(mods_folder, path, file)
            target_dir = os.path.join(server_path(), path)
            target = os.path.join(target_dir, file)

            if os.path.islink(target):
                os.unlink(target)

            print(f"Symlinking \n\t{source} => \n\t{target}")
            os.makedirs(target_dir, exist_ok=True)
            os.symlink(source, target)


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


@invoke.task
def update_dns(ctx: invoke.Context):
    result = ctx.run("curl -4 ifconfig.co", echo=True)
    if result:
        ip_address = result.stdout.strip()
    else:
        raise RuntimeError("Failed to retrieve IP address")
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
def copy_systemd(ctx: invoke.Context):
    ctx.run("chmod +x ./scripts/*", echo=True)
    systemd_files = os.listdir("./systemd")
    for systemd_file in systemd_files:
        ctx.run(f"sudo cp ./systemd/{systemd_file} /etc/systemd/system/", echo=True)
        ctx.run(f"sudo systemctl enable {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl start {systemd_file}", echo=True)
        ctx.run(f"sudo systemctl restart {systemd_file}", echo=True)


#######
# ECO #
#######


@invoke.task
def eco_tail(ctx: invoke.Context):
    ctx.run("journalctl -u eco-server -f", echo=True)


@invoke.task
def eco_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart eco-server", echo=True)


@invoke.task
def eco_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop eco-server", echo=True)
    ctx.run("sudo systemctl disable eco-server", echo=True)


@invoke.task
def eco_start(ctx: invoke.Context):
    ctx.run("sudo systemctl start eco-server", echo=True)
    ctx.run("sudo systemctl enable eco-server", echo=True)


@invoke.task
def eco_symlink_public_mod(_: invoke.Context, mod: str):
    symlink_mods(PUBLIC_MODS_FOLDER, mod)


@invoke.task
def eco_symlink_private_mod(_: invoke.Context, mod: str):
    symlink_mods(PRIVATE_MODS_FOLDER, mod)


@invoke.task
def eco_copy_configs(ctx: invoke.Context):
    # Clean out configs folder
    print("Cleaning out configs folder")
    if os.path.exists("./eco-server/configs"):
        shutil.rmtree("./eco-server/configs", ignore_errors=False, onerror=handleRemoveReadonly)

    # Get configs from git
    ctx.run(
        "git clone --depth 1 git@github.com:coilysiren/eco-configs.git ./eco-server/configs",
        echo=True,
    )

    # Remove .git from target directory
    if os.path.exists(f"{server_path()}/.git"):
        shutil.rmtree(f"{server_path()}/.git", ignore_errors=False, onerror=handleRemoveReadonly)

    # Copy .git to target directory
    print("Copying .git to server")
    shutil.copytree("./eco-server/configs/.git", f"{server_path()}/.git", dirs_exist_ok=True)

    # Copy configs to server, except world gen
    print("Copying configs to server")
    configs = os.listdir("./eco-server/configs/Configs")
    for config in configs:
        if config.split(".")[-1] != "template" and config.split(".")[-2] != "WorldGenerator":
            config_path = os.path.join(server_path(), "Configs", config)
            if os.path.exists(config_path):
                os.remove(config_path)
            print(f"\tCopying ./eco-server/configs/Configs/{config} to {config_path}")
            shutil.copyfile(f"./eco-server/configs/Configs/{config}", config_path)

    # Copy over world gen, but keep the seed intact
    print("Copying WorldGenerator.eco to server")
    with open(os.path.join(server_path(), "Configs", "WorldGenerator.eco"), "r", encoding="utf-8") as file:
        old_world_generator = json.load(file)
        seed = old_world_generator["HeightmapModule"]["Source"]["Config"]["Seed"]
    with open(os.path.join("./eco-server/configs/Configs", "WorldGenerator.eco"), "r", encoding="utf-8") as file:
        new_world_generator = json.load(file)
        new_world_generator["HeightmapModule"]["Source"]["Config"]["Seed"] = seed
    with open(os.path.join(server_path(), "Configs", "WorldGenerator.eco"), "w", encoding="utf-8") as file:
        json.dump(new_world_generator, file, indent=4)


@invoke.task
def eco_copy_private_mods(ctx: invoke.Context, branch=""):
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

    copy_mods()


@invoke.task
def eco_copy_public_mods(ctx: invoke.Context, branch=""):
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

    copy_mods()


@invoke.task
def eco_run(ctx: invoke.Context, offline=False):
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

    print("Modifying DiscordLink.eco to remove BotToken")
    with open(os.path.join(server_path(), "Configs", "DiscordLink.eco"), "r", encoding="utf-8") as file:
        discord = json.load(file)
        discord["BotToken"] = ""
    with open(os.path.join(server_path(), "Configs", "DiscordLink.eco"), "w", encoding="utf-8") as file:
        json.dump(discord, file, indent=4)

    print("Modifying difficulty.eco to speed up world")
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GameSpeed"] = "VeryFast"
    with open(os.path.join(server_path(), "Configs", "Network.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)

    print("Creating sleep.eco to allow time to fast forward")
    with open(os.path.join(server_path(), "Configs", "Sleep.eco"), "w", encoding="utf-8") as file:
        json.dump(
            {"AllowFastForward": True, "SleepTimePassMultiplier": 1000, "TimeToReachMaximumTimeRate": 5},
            file,
            indent=4,
        )

    # get API key
    def get_api_key():
        print("Getting API key")
        response = ssm.get_parameter(
            Name="/eco/server-api-token",
            WithDecryption=True,
        )
        return response["Parameter"]["Value"].strip()

    token = "" if offline else f" -userToken={get_api_key()}"

    # run server
    os.chdir(server_path())
    ctx.run(f"{eco_binary()}{token}", echo=True)


@invoke.task
def eco_generate_same_world(_: invoke.Context):
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
        difficulty["GameSettings"]["GenerateRandomWorld"] = False
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)


@invoke.task
def eco_generate_new_world(_: invoke.Context):
    if os.path.exists(os.path.join(server_path(), "Storage")):
        print("Removing Storage folder")
        shutil.rmtree(
            os.path.join(server_path(), "Storage"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )
    if os.path.exists(os.path.join(server_path(), "Logs")):
        print("Removing Logs folder")
        shutil.rmtree(
            os.path.join(server_path(), "Logs"),
            ignore_errors=False,
            onerror=handleRemoveReadonly,
        )

    print("Modifying WorldGenerator.eco to set seed to 0")
    with open(os.path.join(server_path(), "Configs", "WorldGenerator.eco"), "r", encoding="utf-8") as file:
        world_generator = json.load(file)
        world_generator["HeightmapModule"]["Source"]["Config"]["Seed"] = 0
    with open(os.path.join(server_path(), "Configs", "WorldGenerator.eco"), "w", encoding="utf-8") as file:
        json.dump(world_generator, file, indent=4)

    print("Modifying difficulty.eco to generate random world")
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8") as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = True
    with open(os.path.join(server_path(), "Configs", "Difficulty.eco"), "w", encoding="utf-8") as file:
        json.dump(difficulty, file, indent=4)


###############
# CORE KEEPER #
###############


@invoke.task
def core_keeper_tail(ctx: invoke.Context):
    ctx.run("journalctl -u core-keeper-server -f", echo=True)


@invoke.task
def core_keeper_restart(ctx: invoke.Context):
    ctx.run("sudo systemctl restart core-keeper-server", echo=True)


@invoke.task
def core_keeper_stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop core-keeper-server", echo=True)
    ctx.run("sudo systemctl disable core-keeper-server", echo=True)


@invoke.task
def core_keeper_start(ctx: invoke.Context):
    ctx.run("sudo systemctl start core-keeper-server", echo=True)
    ctx.run("sudo systemctl enable core-keeper-server", echo=True)
