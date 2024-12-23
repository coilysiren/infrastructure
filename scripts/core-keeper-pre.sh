#!/usr/bin/env bash

set -eux

/usr/games/steamcmd +force_install_dir "/home/kai/Steam/steamapps/common/CoreKeeperServer" +login balrore +app_update 1007 validate +app_update 1963720 validate +quit
