# eco-server

## eco server download

=> https://play.eco/account

## init

```bash
export DEBIAN_FRONTEND=noninteractive

sudo apt install -y awscli unzip libssl-dev

# via https://wiki.play.eco/en/Server_on_Linux
sudo apt install -y libgdiplus libc6-dev

# via https://stackoverflow.com/questions/72108697/when-i-open-unity-and-make-something-project-then-the-error-is-coming-that-no
wget http://security.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb
sudo dpkg -i libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb

mkdir -p /home/ubuntu/games/eco
cd /home/ubuntu/games/eco

aws s3 cp s3://coilysiren-assets/downloads/EcoServerLinux .
unzip EcoServerLinux
chmod a+x EcoServer
```
