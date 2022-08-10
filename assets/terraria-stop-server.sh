#!/usr/bin/env bash
# shellcheck disable=SC2006 # backticks are intentional

set -eux

screen -S terraria -X stuff "`printf \"exit\r\"`"
