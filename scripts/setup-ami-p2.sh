#!/usr/bin/env bash

# shellcheck disable=SC1091 # dont try to lint /etc/os-release, its a generated file

set -eux

# runs docker + AMI shared install scripts
/home/ubuntu/scripts/setup-shared.sh

# Add Docker's official GPG key:
sudo apt-get update -qq
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

# setup docker permissions for ubuntu user
sudo usermod -aG docker ubuntu
newgrp docker
sudo su ubuntu
mkdir -p /home/ubuntu/.docker
sudo chown ubuntu:ubuntu /home/ubuntu/.docker -R
sudo chmod g+rwx /home/ubuntu/.docker -R

# start docker on boot
sudo systemctl enable docker.service
sudo systemctl enable containerd.service
