#!/usr/bin/env bash
# shellcheck disable=SC1091 # dont try to lint /home/ubuntu/.bashrc file
# shellcheck disable=SC2016 # dont worry about the unexpanded $PATH in single quotes

set -eux

# holding pen for bin scripts
mkdir -p /home/ubuntu/.local/bin
if ! grep -q "home/ubuntu" "/home/ubuntu/.bashrc"; then
 echo 'export PATH="/home/ubuntu/.local/bin:$PATH"' | tee -a /home/ubuntu/.bashrc
fi
set +x && . /home/ubuntu/.bashrc && set -x

# general installs
sudo echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections
sudo apt-get update -qq
sudo apt-get install -qq -y --no-install-recommends python3-pip unzip libssl-dev libgdiplus libc6-dev unattended-upgrades multitail

# via https://forum.unity.com/threads/workaround-for-libssl-issue-on-ubuntu-22-04.1271405/
wget -P /tmp -q http://security.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb
sudo apt-get install -qq -y --no-install-recommends /tmp/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb

# aws cli
curl -q 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'
unzip -qq -u awscliv2.zip
sudo ./aws/install
aws --version
aws configure set default.region us-east-1

# eco system service
sudo mv /tmp/*.service /etc/systemd/system/

# python packages
mv /tmp/requirements.txt /home/ubuntu/requirements.txt
python3 -m pip install -q -r /home/ubuntu/requirements.txt

# invoke / tasks.py
mv /tmp/tasks.py /home/ubuntu/tasks.py
chmod a+x /home/ubuntu/tasks.py
cd /home/ubuntu/
invoke --list

# cleanup
sudo rm -rf /tmp
