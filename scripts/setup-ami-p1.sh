#!/usr/bin/env bash

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
