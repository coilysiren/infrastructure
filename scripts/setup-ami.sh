#!/usr/bin/env bash

# shellcheck disable=SC1091 # dont try to lint /etc/os-release, its a generated file

set -eux

# make logs dir world writeable
sudo chmod 777 /var/log/
sudo chown -R ubuntu /var/log/

# move scripts files
mkdir -p /home/ubuntu/scripts
mv -vn /tmp/scripts/* /home/ubuntu/scripts/

# move systemd service files
sudo mv -vn /tmp/systemd/* /etc/systemd/system/

# allow running scripts
chmod a+x /home/ubuntu/scripts/*

# runs docker + AMI shared install scripts
/home/ubuntu/scripts/setup-shared.sh

# Add Docker's official GPG key:
sudo apt-get update -qq
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq

# Finally install docker
sudo apt-get install -qq -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
