#!/usr/bin/env bash

set -eux

# make logs dir world writeable
sudo chmod 777 /var/log/
sudo chown -R ubuntu /var/log/

# move scripts files
mkdir -p /home/ubuntu/scripts
cp /tmp/scripts/* /home/ubuntu/scripts/

# move systemd service files
sudo cp /tmp/systemd/* /etc/systemd/system/

# allow running scripts
chmod a+x /home/ubuntu/scripts/*

# general installs
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
  curl \
  ca-certificates \
  jq \
  moreutils

# eco install deps
/home/ubuntu/scripts/install.sh

# aws cli
curl -q 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'
unzip -qq -u awscliv2.zip
sudo ./aws/install --update
aws --version
aws configure set default.region us-east-1
rm -rf awscliv2.zip

# final cleanup
rm -rf /tmp/*
