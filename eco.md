# Eco Server Setup

https://store.steampowered.com/app/382310/Eco/

https://wiki.play.eco/en/Setting_Up_a_Server

This is my editors notes on the Eco server setup instructions from the wiki link above. They should follow the above instructions exactly when possible, and diverge when required. At the end of this process, you should be able to connect to a running Eco server via your Steam client on a different machine.

## 1. Download Eco

Login to https://play.eco/account

On this page, there will be a "Linux Server" option. Click that. It will download that latest stable server, with its version number appended to its filename. Example:

```text
https://play.eco/s3/release/EcoServerLinux_v0.11.1.1-beta.zip
```

(feel encouraged to update the above, plus all other entries, to the version you are deploying at time of reading)
dm
This will go into your `~/Downloads` folder. You'll want to rename it to something more reliable. Then push it into s3, then pull it onto your game server.

```bash
mkdir -p ~/Downloads
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/EcoServerLinux_v0.11.1.1-beta.zip EcoServer.zip
invoke push-asset-local EcoServer.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco/ EcoServer.zip
```

## 3. Install new Eco code

```bash
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/__core__/*"
invoke ssh --cmd "cd /home/ubuntu/games/eco/ && unzip -o EcoServer.zip"
invoke ssh --cmd "chmod a+x /home/ubuntu/games/eco/EcoServer"
```

### Sync Public Mods

```bash
invoke copy-public-mods
(cd ./eco-server/mods/Mods && zip -r EcoUserModsFolder.zip .)
invoke push-asset-local --cd ./eco-server/mods/Mods/ EcoUserModsFolder.zip
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/UserCode/"
invoke pull-asset-remote --cd /home/ubuntu/games/eco/Mods/ EcoUserModsFolder.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco/Mods/ && unzip -o EcoUserModsFolder.zip"
```

### Sync Private Mods

```bash
invoke copy-private-mods --branch cycle-2
(cd ./eco-server/mods/Mods && zip -r EcoPrivateModsFolder.zip .)
invoke push-asset-local --cd ./eco-server/mods/Mods/ EcoPrivateModsFolder.zip

# TODO: automate
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/OpenNutriView/"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/MightyMoose/"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/NidToolbox/"

invoke pull-asset-remote --cd /home/ubuntu/games/eco/Mods/ EcoPrivateModsFolder.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco/Mods/ && unzip -o EcoPrivateModsFolder.zip"
```

## 5. Start the Eco Server

As of late 2024 Eco servers require an API key to run. This is a good change on their
part! For our next step, we configure the server to use the API key.

```bash
invoke ssh --comment
```

Take note of the command above. One line will start with "sso -o...". Exit your server,
copy that line, and then run it yourself. This is necessary because we need to "manually"
ssh into the server in order to get a terminal with edit privileges.

After you run `ssh -o ...`, you run

```bash
sudo nano /etc/systemd/system/eco-server.service
```

Which will open a file editor. Delete the whole file, and fill it in with the following:

```bash
[Unit]
Description=eco-server
After=syslog.target network.target nss-lookup.target network-online.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=simple
Restart=on-failure
TimeoutStopSec=120
RestartSec=5
User=ubuntu
WorkingDirectory=/home/ubuntu/games/eco
ExecStart=/home/ubuntu/games/eco/EcoServer -userToken=YOUR_TOKEN_FROM_THE_WEBSITE
ExecStop=kill -TERM $MAINPID

[Install]
WantedBy=multi-user.target
```

Where `YOUR_TOKEN_FROM_THE_WEBSITE` above is your token filled in from the website
https://play.eco/account.

After doing this, you'll want to reboot the eco server so that it starts with your token.

```bash
invoke reboot
```

Run the following command 5 ~ 10 times, each 1 minute apart, while you wait for the
server to restart.

```bash
invoke eco-tail
```

Eventually it will succeed, and you'll start seeing Eco logs!

## 6. Configure Discord Link

Get the MightyMoose core library from here: https://mod.io/g/eco/m/mightymoosecore

Its download will look like: mightymoosecore_121-kzpm.zip

We want to push that to our Eco server, and unzip it. Like so:

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/mightymoosecore_121-kzpm.zip ~/Downloads/mightymoosecore.zip
invoke push-asset-local --cd ~/Downloads mightymoosecore.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco mightymoosecore.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o mightymoosecore.zip"
```

Then we download discord link, from here: https://mod.io/g/eco/m/discordlink

We push that to our Eco server as well:

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/discordlink_351-0ehu.zip ~/Downloads/discordlink.zip
invoke push-asset-local --cd ~/Downloads discordlink.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco discordlink.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o discordlink.zip"
```

## 6. Configure Chronicler

Get the MightyMoose core library from here: https://mod.io/g/eco/m/mightymoosecore

Its download will look like: mightymoosecore_121-kzpm.zip

We want to push that to our Eco server, and unzip it. Like so:

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/mightymoosecore_121-kzpm.zip ~/Downloads/mightymoosecore.zip
invoke push-asset-local --cd ~/Downloads mightymoosecore.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco mightymoosecore.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o mightymoosecore.zip"
```

Then we download Chronicler, from here: https://mod.io/g/eco/m/chronicler

We push that to our Eco server as well:

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/chronicler_181-bldy.zip ~/Downloads/chronicler.zip
invoke push-asset-local --cd ~/Downloads chronicler.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco chronicler.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o chronicler.zip"
```

Chronicler requires SQLite. The instructions for that are here: https://forum.play.eco/thread/2217-guide-sqlite-chronicler-on-linux/

The commands are replicated here for ease of use.

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/sqlite-netFx-full-source-1.0.116.0.zip ~/Downloads/sqlite.zip
invoke push-asset-local --cd ~/Downloads sqlite.zip
invoke ssh --cmd "mkdir -p /home/ubuntu/software/sqlite"
invoke pull-asset-remote --cd /home/ubuntu/software/sqlite sqlite.zip
invoke ssh --cmd "cd /home/ubuntu/software/sqlite && unzip -o sqlite.zip"
invoke ssh --cmd "cd /home/ubuntu/software/sqlite/Setup && chmod a+x ./compile-interop-assembly-release.sh"
invoke ssh --cmd "cd /home/ubuntu/software/sqlite/Setup && ./compile-interop-assembly-release.sh"
invoke ssh --cmd "sudo cp /home/ubuntu/software/sqlite/bin/2013/Release/bin/libSQLite.Interop.so /usr/lib"
invoke ssh --cmd "rm /home/ubuntu/games/eco/Mods/MightyMoose/Chronicler/SQLite.Interop.dll"
```

## 7. Configure NidToolBox

The mod and its desired modules are available here:

- https://mod.io/g/eco/m/nidtoolbox
- https://mod.io/g/eco/m/nidtoolbox-clean-server-module
- https://mod.io/g/eco/m/nidtoolbox-player-manager-module

```bash
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/nid-core_2112-1kc8.zip ~/Downloads/nid-core.zip
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/nid-cleanserver_2111-c3i4.zip ~/Downloads/nid-cleanserver.zip
cp /mnt/c/Users/$WINDOWSUSERNAME/Downloads/nid-playermanager_2112-ee7a.zip ~/Downloads/nidtoolbox-playermanager.zip
invoke push-asset-local --cd ~/Downloads nid-core.zip
invoke push-asset-local --cd ~/Downloads nid-cleanserver.zip
invoke push-asset-local --cd ~/Downloads nidtoolbox-playermanager.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco nid-core.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco nid-cleanserver.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco nidtoolbox-playermanager.zip
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o nid-core.zip"
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o nid-cleanserver.zip"
invoke ssh --cmd "cd /home/ubuntu/games/eco && unzip -o nidtoolbox-playermanager.zip"
```

Then we need to create the configuration files. I'll post mine here for your reference:

```bash
mkdir -p home/ubuntu/games/eco/Configs/NidToolbox
```

```bash
code home/ubuntu/games/eco/Configs/NidToolbox/GeneralSettings.json
```

```json
// GeneralSettings.json
{
  "Info1": "NidToolbox Light: General settings.",
  "Info2": "CommandFeedbackString appears in between brackets: [NidToolbox]: Some text.",
  "Info3": "ServerTag is used in announcements as server name: SERVER: Some text. ",
  "Info4": "ServerIconId is identifies server icon in assets. It shows in mail.",
  "Info5": "ServerIconId can also be used on objects like signs and messages text in popups.",
  "Info6": "-----------------------------------------------------------------------------------",
  "CommandFeedbackString": "<color=#50C878>[NidToolbox]: ",
  "ServerTag": "SERVER",
  "ServerIconId": "NidToolbox",
  "ForceTimezone": "Pacific Standard Time",
  "BlackListed": false
}
```

```bash
code home/ubuntu/games/eco/Configs/NidToolbox/ServerCleaner.json
```

```json
// ServerCleaner.json
{
  "Info1": "NidToolbox Light: Server Cleaner Settings.",
  "Info2": "------------------------------------------",
  "CleanPeriodically": false,
  "CleanEveryMinutes": 1440.0,
  "CleanAtScheduledTime": true,
  "ScheduledTime": ["3:00"],
  "CleanMiningRubble": true,
  "CleanTreeDebris": true,
  "CleanFallenTrees": false,
  "CleanStumps": false,
  "CleanTailingsNotContained": false,
  "CleanTailingsInStorages": false,
  "CleanWetTailingsNotContained": false,
  "CleanWetTailingsInStorages": false,
  "ReportInConsole": true,
  "ReportInLog": true,
  "BlackListed": false
}
```

```bash
code home/ubuntu/games/eco/Configs/NidToolbox/PlayerManager.json
```

```json
// PlayerManager.json
{
  "Info1": "NidToolbox Light: Player Manager settings.",
  "ShowIPinTooltip": true,
  "ShowSteamIdinTooltip": true,
  "ShowSlgIdInTooltip": true,
  "ShowShopsInTooltip": true,
  "EnableUserVehicleRescueCommand": true,
  "UserVehicleCommandCooldownMinutes": 120.0,
  "BlackListed": false
}
```

Then we sync all of the configs, via the "Sync Configs" instructions above.

## 8. Resets

### Reset Game State But Keep Map

Modify `GenerateRandomWorld` in `Difficulty.eco` to `false`, backup the `WorldGenerator.eco` file, then delete the `Storage` directory.

### Reset Game State And Get Random Map

Modify `GenerateRandomWorld` in `Difficulty.eco` to `true`, then delete the `Storage` directory.
