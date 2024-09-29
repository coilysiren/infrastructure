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
mkdir -p ~/Downloads
cp /mnt/c/Users/$username/Downloads/EcoServerLinux_v0.11.0.6-beta.zip ~/Downloads/EcoServer.zip
invoke push-asset-local EcoServer.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco/ EcoServer.zip
```

## 2. Clear out old Eco installation

If this is isn't the first time you're deploying an Eco game server, you might have a filesystem  version of Eco stored on it. You'll want to remove the old server application code, and the old mods, and saves (RIP).

```bash
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/__core__/*"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/UserCode/*"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Logs/*"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Storage/*"
```

## 3. Install new Eco code

```bash
invoke ssh --cmd "cd /home/ubuntu/games/eco/ && unzip EcoServer.zip"
invoke ssh --cmd "chmod a+x EcoServer"
invoke ssh --cmd "chmod a+x install.sh"
invoke ssh --cmd "cd ~/games/eco && ./install.sh"
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
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Configs"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/__core__/*"
invoke ssh --cmd "rm -rf /home/ubuntu/games/eco/Mods/UserCode/*"

(cd home/ubuntu/games/eco/ && zip -r EcoCoreFolder.zip Mods/__core__)
(cd home/ubuntu/games/eco/ && zip -r EcoUserFolder.zip Mods/UserCode)
(cd home/ubuntu/games/eco/ && zip -r EcoConfigFolder.zip Configs)

invoke push-asset-local --cd home/ubuntu/games/eco/ EcoCoreFolder.zip
invoke push-asset-local --cd home/ubuntu/games/eco/ EcoUserFolder.zip
invoke push-asset-local --cd home/ubuntu/games/eco/ EcoConfigFolder.zip

invoke pull-asset-remote --cd /home/ubuntu/games/eco/ EcoCoreFolder.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco/ EcoUserFolder.zip
invoke pull-asset-remote --cd /home/ubuntu/games/eco/ EcoConfigFolder.zip

invoke ssh --cmd "cd ~/games/eco && unzip -o EcoCoreFolder.zip"
invoke ssh --cmd "cd ~/games/eco && unzip -o EcoUserFolder.zip"
invoke ssh --cmd "cd ~/games/eco && unzip -o EcoConfigFolder.zip"
```

## 5. Start the Eco Server

As of late 2024 Eco servers require an API key to run. This is a good change on their
part! For our next step, we configure the server to use the API key.

```bash
invoke ssh
# TDOD add invoke ssh --comment to output the ssh command with some helpful text,
#   instead of actually trying to ssh.
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
