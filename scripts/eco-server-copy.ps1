#!/usr/bin/env pwsh

$LINUX_SERVER_PATH = "/home/kai/.local/share/Steam/steamapps/common/Eco/Eco_Data/Server/"

function Invoke-AndEcho {
  param (
    [string]$Command
  )
  Write-Host "Running: $Command"
  Invoke-Expression $Command
}

Invoke-AndEcho "ssh kai@kai-server 'rm -rf $LINUX_SERVER_PATH/Mods/__core__/*'"
Invoke-AndEcho "Copy-Item -Path ~/Downloads/EcoServerLinux.zip -Destination ."
Invoke-AndEcho "scp EcoServerLinux.zip kai@kai-server:$LINUX_SERVER_PATH"
Invoke-AndEcho "ssh kai@kai-server 'cd $LINUX_SERVER_PATH && unzip -o EcoServerLinux.zip'"
