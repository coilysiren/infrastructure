#!/usr/bin/env bash

set -eux

/usr/games/steamcmd +force_install_dir "/home/steam/Steam/steamapps/common/Eco Server" +login balrore +app_update 739590 validate +quit
