#!/usr/bin/env bash

set -eux

/usr/bin/docker image prune --all --force
/usr/bin/docker stop eco-server
/usr/bin/docker rm eco-server