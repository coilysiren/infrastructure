#!/usr/bin/bash

eco_server_api_token=$(aws ssm get-parameter --name /eco/server-api-token --with-decryption --query Parameter.Value --output text)
discord_bot_token=$(aws ssm get-parameter --name /eco/discord-bot-token --with-decryption --query Parameter.Value --output text)

# Inject Discord bot token into DiscordLink.eco config
config_path="/home/kai/Steam/steamapps/common/EcoServer/Configs/DiscordLink.eco"
if [ -f "$config_path" ]; then
    tmp=$(mktemp)
    jq --arg token "$discord_bot_token" '.BotToken = $token' "$config_path" > "$tmp" && mv "$tmp" "$config_path"
fi

chmod a+x "/home/kai/Steam/steamapps/common/EcoServer/EcoServer"
"/home/kai/Steam/steamapps/common/EcoServer/EcoServer" -userToken="$eco_server_api_token"
