#!/usr/bin/env bash

set -eux

mkdir -p /home/ubuntu/games/terraria/
mkdir -p /home/ubuntu/games/terraria-config/
mkdir -p /home/ubuntu/games/terraria-logs/

timestamp=$(date +%s)

/home/ubuntu/games/terraria/TerrariaServer \
  -config /home/ubuntu/games/terraria-config/serverconfig.txt \
  >> "/home/ubuntu/games/terraria-logs/$timestamp-out.txt" \
  2> "/home/ubuntu/games/terraria-logs/$timestamp-err.txt"
