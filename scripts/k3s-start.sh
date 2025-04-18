#!/bin/bash

cleanup() {
  pkill -9 containerd-shim
  pkill -9 containerd
  pkill -9 k3s
  exit 0
}

trap cleanup SIGTERM SIGINT

/usr/local/bin/k3s server
