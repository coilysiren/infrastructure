#!/usr/bin/bash

/usr/games/steamcmd +force_install_dir "/home/kai/Steam/steamapps/common/EcoServer" +login balrore +app_update 739590 validate +quit
cd /home/kai/projects/infrastructure && /home/kai/.pyenv/shims/inv eco.increase-skill-gain --multiplier 1.1
