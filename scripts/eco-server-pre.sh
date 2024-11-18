#!/usr/bin/env bash

set -eux

/usr/games/steamcmd +force_install_dir "/home/steam/Steam/steamapps/common/EcoServer" +login balrore +app_update 739590 validate +quit
