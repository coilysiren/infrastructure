# Eco Server Setup

https://store.steampowered.com/app/382310/Eco/

https://wiki.play.eco/en/Setting_Up_a_Server

This is my editors notes on the Eco server setup instructions from the wiki link above. They should follow the above instructions exactly when possible, and diverge when required. At the end of this process, you should be able to connect to a running Eco server via your Steam client on a different machine.

## 1. Download Eco

Login to https://play.eco/account

On this page, there will be a "Linux Server" option. Click that. It will download that latest stable server, with its version number appended to its filename. Example:

```text
https://play.eco/s3/release/EcoServerLinux_v0.11.0.6-beta.zip
```

(feel encouraged to update the above, plus all other entries, to the version you are deploying at time of reading)
dm
This will go into your `~/Downloads` folder. You'll want to rename it to something more reliable. Then push it into s3, then pull it onto your game server.

```bash
# run on your local machine:
mv ~/Downloads/EcoServerLinux_v0.11.0.6-beta.zip ~/Downloads/EcoServer.zip
invoke push-asset-local EcoServer.zip # from local into an s3 bucket
invoke pull-asset-remote EcoServer.zip # pulls from s3 bucket into the remote server
# Why doesn't this use scp? There's a scp command in the same invoke file.
```

Inside Ubuntu on WSL that would be:

```bash
# run on your local machine:
mkdir -p ~/Downloads
cp /mnt/c/Users/$username/Downloads/EcoServerLinux_v0.11.0.6-beta.zip ~/Downloads/EcoServer.zip
invoke push-asset-local EcoServer.zip # from local into an s3 bucket
invoke pull-asset-remote EcoServer.zip # pulls from s3 bucket into the remote server
# Why doesn't this use scp? There's a scp command in the same invoke file.
```

## 2. Clear out old Eco installation

If this is isn't the first time you're deploying an Eco game server, you might have a filesystem  version of Eco stored on it. You'll want to remove the old server application code, and the old mods, and saves (RIP).

```bash
# run on your local machine:
invoke ssh
rm -rf /home/ubuntu/games/eco/Mods/__core__/* # remove old application code
rm -rf /home/ubuntu/games/eco/Mods/UserCode/* # mods
rm -rf /home/ubuntu/games/eco/Logs/* # logs
rm -rf /home/ubuntu/games/eco/Storage/* # save file (RIP)
```

## 3. Install new Eco code

```bash
# run on your local machine:
invoke ssh
rm -rf tmp/
unzip EcoServer.zip -d tmp # unzip new code
cp -rv tmp/* eco # copy it over
rm -rf tmp/
cd eco
chmod a+x EcoServer
chmod a+x install.sh
```

## 4. Configure Eco

For this step you'll be pulling the entirety of your Eco server folder into a text editor
so that you can configure it. No pressure!!! Follow instructions on the Eco wiki and
various online tutorials to consult how to modify the files themselves. This document
only shows you how to push and pull the files back and forth.

AT NOT POINT SHOULD YOU BE SHOWING PEOPLE THE FILES YOU ARE ABOUT TO SEE. ITS ILLEGAL.
Which is to say, it is against Eco's license. You would be opening yourself up to
lawsuits, and also you would just generally be a bad person.

Here we go! The following commands were written for WSL and VSCode, the best text editor.

```bash
# TODO: Add zip command into the AMI, and ripgrep while you are at it
# run on your local machine:
invoke ssh --cmd "cd ~/games && zip -r EcoCoreFolder.zip /home/ubuntu/games/eco/Mods/__core__/"
invoke ssh --cmd "cd ~/games && zip -r EcoUserFolder.zip /home/ubuntu/games/eco/Mods/UserCode/"
invoke ssh --cmd "cd ~/games && zip -r EcoConfigFolder.zip /home/ubuntu/games/eco/Configs/"

invoke push-asset-remote EcoCoreFolder.zip
invoke push-asset-remote EcoUserFolder.zip
invoke push-asset-remote EcoConfigFolder.zip
invoke pull-asset-local EcoCoreFolder.zip
invoke pull-asset-local EcoUserFolder.zip
invoke pull-asset-local EcoConfigFolder.zip

rm -rf home/ubuntu/games/eco
unzip ~/Downloads/EcoCoreFolder.zip
unzip ~/Downloads/EcoUserFolder.zip
unzip ~/Downloads/EcoConfigFolder.zip
code home/ubuntu/games/eco/
```

Make your edits, again, consulting the wiki and online tutorials as needed. And then...

```bash
# run on your local machine:
invoke ssh
rm -rf /home/ubuntu/games/eco/Mods/__core__/* # remove old application code
rm -rf /home/ubuntu/games/eco/Mods/UserCode/* # mods
# then you exit the server, and again on your local machine, run:
# TODO...
```

## 5. Start the Eco Server

```bash
# run on your local machine:
invoke ssh
cd eco
./install.sh
# then you exit the server, and again on your local machine, run:
invoke eco-restart
invoke eco-tail
```

Note that the above command may take a while! 5 ~ 20 minutes before it fully stablizes.

## 6. Syncing Mods

```bash
# TODO
invoke scp --source eco-mod-cache/ShovelItem.override.cs --destination /home/ubuntu/games/eco/Mods/UserCode/Tools
```
