#!/usr/bin/env bash

set -eux

screen -D -m -S terraria -L -Logfile /var/log/terraria-screen.log /bin/bash -c " \
  /home/ubuntu/games/terraria/TerrariaServer \
    -config /home/ubuntu/games/terraria-config/serverconfig.txt \
    1>> /var/log/terraria-server-stdout.log \
    2>> /var/log/terraria-server-stderr.log
  "
