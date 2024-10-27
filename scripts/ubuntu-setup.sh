#!/usr/bin/env bash
# shellcheck disable=SC1091 # dont try to lint /home/ubuntu/.bashrc file
# shellcheck disable=SC2016 # dont worry about the unexpanded $PATH in single quotes
# shellcheck disable=SC2028 # dont worry about the unexpanded escape sequences in echoes

set -eux

# make logs dir world writeable
sudo chmod 777 /var/log/
sudo chown -R ubuntu /var/log/

# holding pen for bin scripts
mkdir -p /home/ubuntu/.local/bin

# general installs
sudo echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
sudo apt-get update -qq
sudo apt-get install -qq -y --no-install-recommends \
  python3-pip \
  unzip \
  libssl-dev \
  libgdiplus \
  libc6-dev \
  unattended-upgrades \
  multitail \
  screen \
  ripgrep \
  unzip \
  gcc \
  moreutils

# generate bashrc
true >/home/ubuntu/.bashrc
echo 'export PATH="/home/ubuntu/.local/bin:$PATH"' |
  sponge -a /home/ubuntu/.bashrc
echo 'alias python=python3' |
  sponge -a /home/ubuntu/.bashrc
echo 'export TERM=xterm' |
  sponge -a /home/ubuntu/.bashrc
echo 'export HISTCONTROL=ignoreboth' |
  sponge -a /home/ubuntu/.bashrc
echo 'export export HISTSIZE=1000' |
  sponge -a /home/ubuntu/.bashrc
echo 'export export HISTFILESIZE=2000' |
  sponge -a /home/ubuntu/.bashrc
echo 'export GCC_COLORS="error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01"' |
  sponge -a /home/ubuntu/.bashrc
echo 'alias ls="ls -GFh --color=auto"' |
  sponge -a /home/ubuntu/.bashrc
echo 'export PS1="\n\u@\H \w [\t]\n\[$(tput sgr0)\]\$ "' |
  sponge -a /home/ubuntu/.bashrc
source /home/ubuntu/.bashrc

# aws cli
curl -q 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'
unzip -qq -u awscliv2.zip
sudo ./aws/install --update
aws --version
aws configure set default.region us-east-1

# game server systemd services and startup scripts
sudo mkdir -p /home/ubuntu/scripts
sudo chown -R ubuntu /home/ubuntu/scripts
sudo mv -vn /tmp/*-server.sh /home/ubuntu/scripts
sudo mv -vn /tmp/*-server.service /etc/systemd/system/
chmod a+x /home/ubuntu/scripts/*

# cleanup
sudo rm -rf /tmp
