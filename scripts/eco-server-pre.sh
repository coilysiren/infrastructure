#!/usr/bin/env bash

set -eux

/usr/games/steamcmd +force_install_dir "/home/kai/Steam/steamapps/common/EcoServer" +login balrore +app_update 739590 validate +quit
