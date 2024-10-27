#!/usr/bin/env bash

set -eux

# make logs dir world writeable
sudo chmod 777 /var/log/
sudo chown -R ubuntu /var/log/

# runs docker + AMI install scripts
./scripts/setup-shared.sh

# holding pen for bin scripts
mkdir -p /home/"ubuntu"/.local/bin

# game server systemd services and startup scripts
sudo mkdir -p /home/"ubuntu"/scripts
sudo chown -R "ubuntu" /home/"ubuntu"/scripts
sudo mv -vn /tmp/*-server.sh /home/"ubuntu"/scripts
sudo mv -vn /tmp/*-server.service /etc/systemd/system/
chmod a+x /home/"ubuntu"/scripts/*

# cleanup
sudo rm -rf /tmp
