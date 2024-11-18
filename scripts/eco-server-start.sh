#!/usr/bin/env bash

set -eux

eco_server_api_token=$(aws ssm get-parameter --name /eco/server-api-token --with-decryption --query Parameter.Value --output text)

chmod a+x "/home/kai/.local/share/Steam/steamapps/common/EcoServer/EcoServer"
"/home/kai/.local/share/Steam/steamapps/common/EcoServer/EcoServer" -userToken="$eco_server_api_token"
