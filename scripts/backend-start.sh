#!/usr/bin/bash

bsky_password=$(aws ssm get-parameter --name /bsky/password --with-decryption --query Parameter.Value --output text)

env \
  PYTHONPATH=. \
  BSKY_USERNAME="coilysiren.me" \
  BSKY_PASSWORD="$bsky_password" \
  /home/kai/.pyenv/shims/uvicorn \
  src.main:app --port 4000 --host 0.0.0.0
