# Eco Server Setup

https://store.steampowered.com/app/382310/Eco/

https://wiki.play.eco/en/Setting_Up_a_Server

This is my editors notes on the Eco server setup instructions from the wiki link above. They should follow the above instructions exactly when possible, and diverge when required. At the end of this process, you should be able to connect to a running Eco server via your Steam client on a different machine.

## 1. Download Eco

Login to https://play.eco/account

On this page, there will be a "Linux Server" option. Click that. It will download that latest stable server, with its version number appended to its filename. Example:

```bash
https://play.eco/s3/release/EcoServerLinux_v0.9.7.13-beta.zip
```

This will go into your `~/Downloads` folder. You'll want to rename it to something more reliable. Then push it into s3, then pull it onto your game server.

```bash
mv ~/Downloads/EcoServerLinux_v0.9.7.13-beta.zip ~/Downloads/EcoServer.zip
invoke push-asset EcoServer.zip
invoke pull-asset EcoServer.zip
```

## 2. Clear out old Eco installation

This is the second time I'm deploying an Eco game server, so I have a persistent EBS volume with a 2022 version of Eco stored on it. I want to remove the old server application code, and the old mods and saves (RIP).

```bash
invoke ssh
rm -rf /home/ubuntu/games/eco/Mods/__core__/* # remove old application code
rm -rf /home/ubuntu/games/eco/Mods/UserCode/* # mods
rm -rf /home/ubuntu/games/eco/Logs/* # logs
rm -rf /home/ubuntu/games/eco/Storage/* # save file (RIP)
```

## 3. Install new Eco code

```bash
invoke ssh
rm -rf tmp/
unzip EcoServer.zip -d tmp # unzip new code
cp -rv tmp/* eco # copy it over
rm -rf tmp/
cd eco
chmod a+x EcoServer # these two files don't unzip executable
chmod a+x install.sh
./install.sh
```

## 4. Start the Eco Server

```bash
invoke eco-restart
invoke eco-tail
```

Note that the above command may take a while! 5 ~ 20 minutes before it fully stablizes.

## 5. Syncing Mods

```bash
unzip bigfastshovel.v10-1.0.1-ezqq.zip -d eco-mod-cache
invoke scp --source eco-mod-cache/ShovelItem.override.cs --destination /home/ubuntu/games/eco/Mods/UserCode/Tools
```
