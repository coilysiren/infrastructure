#!/usr/bin/env bash

set -eux

/usr/local/bin/aws ecr get-login-password | \
/usr/bin/docker login \
    -u AWS \
    --password-stdin "{{ aws_account_id }}.dkr.ecr.us-east-1.amazonaws.com"

/usr/bin/docker pull \
    "{{ aws_account_id }}.dkr.ecr.us-east-1.amazonaws.com/eco-server-ecr:{{ env }}"

/usr/bin/docker run --rm \
    --name eco-server \
    -p 3000:3000 \
    -p 3001:3001 \
    -p 3002:3002 \
    -p 3003:3003 \
    --volume /home/ubuntu/data/storage:/home/ubuntu/eco/Storage \
    --volume /home/ubuntu/data/logs:/home/ubuntu/eco/Logs \
    "{{ aws_account_id }}.dkr.ecr.us-east-1.amazonaws.com/eco-server-ecr:{{ env }}" \
    /home/ubuntu/eco/EcoServer -userToken="{{ eco_server_api_token }}"
