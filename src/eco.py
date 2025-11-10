import json
import os
import shutil
import stat

import boto3
import invoke

ssm = boto3.client("ssm", region_name="us-east-1")

PUBLIC_MODS_FOLDER = os.path.join("..", "eco-mods-public")
PRIVATE_MODS_FOLDER = os.path.join("..", "eco-mods")

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


def _get_api_key():
    print("Getting API key")
    response = ssm.get_parameter(
        Name="/eco/server-api-token",
        WithDecryption=True,
    )
    return response["Parameter"]["Value"].strip()


def _handleRemoveReadonly(func, path, _):
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


def _server_path():
    if "windows" in os.getenv("OS", "").lower():
        return WINDOWS_SERVER_PATH
    else:
        return LINUX_SERVER_PATH


def _copy_paths(origin_path, target_path):
    if not os.path.isdir(origin_path):
        return
    # Temporary workaround until I have a smarter merge logic
    if os.path.exists(target_path) and os.path.isdir(target_path) and "BunWulfEducational" not in origin_path:
        print(f"\tRemoving {target_path}")
        shutil.rmtree(target_path, ignore_errors=False, onerror=_handleRemoveReadonly)
    if os.path.isdir(origin_path):
        print(f"\tCopying {origin_path} to {target_path}")
        shutil.copytree(origin_path, target_path, dirs_exist_ok=True)


def _copy_mods():
    print("Copying mods to server")
    mods = os.listdir("./eco-server/mods/Mods")
    for mod in mods:
        origin_path = os.path.join("./eco-server/mods/Mods", mod)
        target_path = os.path.join(_server_path(), "Mods", mod)
        if mod.endswith("UserCode"):
            continue
        _copy_paths(origin_path, target_path)

    print("Copying user code mods to server")
    mods = os.listdir("./eco-server/mods/Mods/UserCode")
    for mod in mods:
        origin_path = os.path.join("./eco-server/mods/Mods/UserCode", mod)
        target_path = os.path.join(_server_path(), "Mods", "UserCode", mod)
        _copy_paths(origin_path, target_path)

    # TODO: handle overrides in UserCode/Tools/, UserCode/Objects/, etc
    # TODO: get the list of overrides by looking inside __core__

    if os.path.exists("./eco-server/mods/Configs"):
        print("Copying mod configs to server")
        shutil.copytree(
            "./eco-server/mods/Configs",
            os.path.join(_server_path(), "Configs"),
            dirs_exist_ok=True,
        )


def _symlink_mods(mods_folder, mod):
    full_source_path = os.path.join(mods_folder, "Mods", "UserCode", mod)
    full_target_path = os.path.join(_server_path(), "Mods", "UserCode", mod)

    if not os.path.exists(full_source_path):
        raise FileNotFoundError(f"{full_source_path} does not exist")

    if os.path.isdir(full_target_path):
        print("Removing existing mod folder")
        shutil.rmtree(
            full_target_path,
            ignore_errors=False,
            onerror=_handleRemoveReadonly,
        )

    path = os.path.join("Mods", "UserCode", mod)

    for dirpath, _, filenames in os.walk(os.path.join(mods_folder, path)):
        for filename in filenames:
            if (
                ("\\bin\\" in dirpath)
                or ("/bin/" in dirpath)
                or ("\\obj\\" in dirpath)
                or ("/obj/" in dirpath)
            ):
                continue
            if filename.endswith(".cs") or filename.endswith(".unity3d"):
                source = os.path.join(dirpath, filename)
                target = os.path.join(
                    source.replace(mods_folder, _server_path()), filename
                )
                if os.path.exists(target):
                    os.remove(target)
                if os.path.islink(target):
                    os.unlink(target)
                print(f"Symlinking \n\t{source} => \n\t{target}")
                os.makedirs(os.path.dirname(target), exist_ok=True)
                os.symlink(source, target)


@invoke.task
def tail(ctx: invoke.Context):
    ctx.run("journalctl -u eco-server -f", echo=True)


@invoke.task
def restart(ctx: invoke.Context):
    ctx.run("sudo systemctl daemon-reload", echo=True)
    ctx.run("sudo systemctl restart eco-server", echo=True)


@invoke.task
def stop(ctx: invoke.Context):
    ctx.run("sudo systemctl stop eco-server", echo=True)
    ctx.run("sudo systemctl disable eco-server", echo=True)


@invoke.task
def start(ctx: invoke.Context):
    ctx.run("sudo systemctl start eco-server", echo=True)
    ctx.run("sudo systemctl enable eco-server", echo=True)


@invoke.task
def symlink_public_mod(_: invoke.Context, mod: str):
    _symlink_mods(PUBLIC_MODS_FOLDER, mod)


@invoke.task
def symlink_private_mod(_: invoke.Context, mod: str):
    _symlink_mods(PRIVATE_MODS_FOLDER, mod)


@invoke.task
def copy_configs(ctx: invoke.Context, with_world_gen=False):
    # Clean out configs folder
    print("Cleaning out configs folder")
    if os.path.exists("./eco-server/configs"):
        shutil.rmtree(
            "./eco-server/configs", ignore_errors=False, onerror=_handleRemoveReadonly
        )

    # Get configs from git
    ctx.run(
        "git clone --single-branch -v --depth 1 git@github.com:coilysiren/eco-configs.git ./eco-server/configs",
        echo=True,
    )

    # Remove .git from target directory
    if os.path.exists(f"{_server_path()}/.git"):
        shutil.rmtree(
            f"{_server_path()}/.git", ignore_errors=False, onerror=_handleRemoveReadonly
        )

    # Copy .git to target directory
    print("Copying .git to server")
    shutil.copytree(
        "./eco-server/configs/.git", f"{_server_path()}/.git", dirs_exist_ok=True
    )

    # Copy configs to server, except world gen
    print("Copying configs to server")
    configs = os.listdir("./eco-server/configs/Configs")
    for config in configs:
        config_path = os.path.join(_server_path(), "Configs", config)
        if os.path.exists(config_path):
            os.remove(config_path)
        print(f"\tCopying ./eco-server/configs/Configs/{config} to {config_path}")
        shutil.copyfile(f"./eco-server/configs/Configs/{config}", config_path)


@invoke.task
def copy_private_mods(ctx: invoke.Context, branch=""):
    print("Cleaning out mods folder")
    if os.path.exists("./eco-server/mods"):
        shutil.rmtree(
            "./eco-server/mods", ignore_errors=False, onerror=_handleRemoveReadonly
        )

    # get mods from git
    branch_flag = ""
    if branch != "":
        branch_flag = f"-b {branch}"
    ctx.run(
        f"git clone --single-branch -v --depth 1 {branch_flag} -- git@github.com:coilysiren/eco-mods.git ./eco-server/mods",
        echo=True,
    )

    _copy_mods()


@invoke.task
def copy_public_mods(ctx: invoke.Context, branch=""):
    print("Cleaning out mods folder")
    if os.path.exists("./eco-server/mods"):
        shutil.rmtree(
            "./eco-server/mods", ignore_errors=False, onerror=_handleRemoveReadonly
        )

    # get mods from git
    branch_flag = ""
    if branch != "":
        branch_flag = f"-b {branch}"
    ctx.run(
        f"git clone --single-branch -v --depth 1 {branch_flag} -- git@github.com:coilysiren/eco-mods-public.git ./eco-server/mods",
        echo=True,
    )

    _copy_mods()


@invoke.task
def run(ctx: invoke.Context, offline=False):
    print("Modifying network.eco to reflect private server")
    with open(
        os.path.join(_server_path(), "Configs", "Network.eco"), "r", encoding="utf-8"
    ) as file:
        network = json.load(file)
        network["PublicServer"] = False
        network["Name"] = "localhost"
        network["IPAddress"] = "Any"
        network["RemoteAddress"] = "localhost:3000"
        network["WebServerUrl"] = "http://localhost:3001"
    with open(
        os.path.join(_server_path(), "Configs", "Network.eco"), "w", encoding="utf-8"
    ) as file:
        json.dump(network, file, indent=4)

    print("Modifying DiscordLink.eco to remove BotToken")
    with open(
        os.path.join(_server_path(), "Configs", "DiscordLink.eco"),
        "r",
        encoding="utf-8",
    ) as file:
        discord = json.load(file)
        discord["BotToken"] = ""
    with open(
        os.path.join(_server_path(), "Configs", "DiscordLink.eco"),
        "w",
        encoding="utf-8",
    ) as file:
        json.dump(discord, file, indent=4)

    print("Modifying difficulty.eco to speed up world")
    with open(
        os.path.join(_server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8"
    ) as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GameSpeed"] = "VeryFast"
    with open(
        os.path.join(_server_path(), "Configs", "Network.eco"), "w", encoding="utf-8"
    ) as file:
        json.dump(difficulty, file, indent=4)

    print("Creating sleep.eco to allow time to fast forward")
    with open(
        os.path.join(_server_path(), "Configs", "Sleep.eco"), "w", encoding="utf-8"
    ) as file:
        json.dump(
            {
                "AllowFastForward": True,
                "SleepTimePassMultiplier": 1000,
                "TimeToReachMaximumTimeRate": 5,
            },
            file,
            indent=4,
        )

    token = "" if offline else f" -userToken={_get_api_key()}"

    # run server
    os.chdir(_server_path())
    ctx.run(f"{eco_binary()}{token}", echo=True)


@invoke.task
def generate_same_world(_: invoke.Context):
    if os.path.exists(os.path.join(_server_path(), "Storage")):
        shutil.rmtree(
            os.path.join(_server_path(), "Storage"),
            ignore_errors=False,
            onerror=_handleRemoveReadonly,
        )
    if os.path.exists(os.path.join(_server_path(), "Logs")):
        shutil.rmtree(
            os.path.join(_server_path(), "Logs"),
            ignore_errors=False,
            onerror=_handleRemoveReadonly,
        )

    print("Modifying difficulty.eco to regenerate world")
    with open(
        os.path.join(_server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8"
    ) as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = False
    with open(
        os.path.join(_server_path(), "Configs", "Difficulty.eco"), "w", encoding="utf-8"
    ) as file:
        json.dump(difficulty, file, indent=4)


@invoke.task
def generate_new_world(_: invoke.Context):
    if os.path.exists(os.path.join(_server_path(), "Storage")):
        print("Removing Storage folder")
        shutil.rmtree(
            os.path.join(_server_path(), "Storage"),
            ignore_errors=False,
            onerror=_handleRemoveReadonly,
        )
    if os.path.exists(os.path.join(_server_path(), "Logs")):
        print("Removing Logs folder")
        shutil.rmtree(
            os.path.join(_server_path(), "Logs"),
            ignore_errors=False,
            onerror=_handleRemoveReadonly,
        )

    print("Modifying WorldGenerator.eco to set seed to 0")
    with open(
        os.path.join(_server_path(), "Configs", "WorldGenerator.eco"),
        "r",
        encoding="utf-8",
    ) as file:
        world_generator = json.load(file)
        world_generator["HeightmapModule"]["Source"]["Config"]["Seed"] = 0
    with open(
        os.path.join(_server_path(), "Configs", "WorldGenerator.eco"),
        "w",
        encoding="utf-8",
    ) as file:
        json.dump(world_generator, file, indent=4)

    print("Modifying difficulty.eco to generate random world")
    with open(
        os.path.join(_server_path(), "Configs", "Difficulty.eco"), "r", encoding="utf-8"
    ) as file:
        difficulty = json.load(file)
        difficulty["GameSettings"]["GenerateRandomWorld"] = True
    with open(
        os.path.join(_server_path(), "Configs", "Difficulty.eco"), "w", encoding="utf-8"
    ) as file:
        json.dump(difficulty, file, indent=4)


eco_collection = invoke.Collection(
    "eco",
    tail,
    restart,
    stop,
    start,
    symlink_public_mod,
    symlink_private_mod,
    copy_configs,
    copy_private_mods,
    copy_public_mods,
    run,
    generate_same_world,
    generate_new_world,
)
