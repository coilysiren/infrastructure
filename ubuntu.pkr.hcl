// docs
// - https://github.com/hashicorp/packer-plugin-amazon/blob/main/docs/builders/ebs.mdx
// - https://learn.hashicorp.com/tutorials/packer/aws-get-started-build-image?in=packer/aws-get-started

packer {
  required_plugins {
    amazon = {
      version = ">= 1.0.9"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "ubuntu-packer" {
  source_ami            = "ami-07d160315197aca8f" // latest free x86 64 bit ubuntu AMI from Canonical - https://aws.amazon.com/marketplace/search
  ami_name              = "ubuntu-packer"
  instance_type         = "t3.micro"
  region                = "us-east-1"
  ssh_username          = "ubuntu"
  force_deregister      = true
  force_delete_snapshot = true
  iam_instance_profile  = "game-server"
}

build {
  name = "ubuntu-packer"
  sources = [
    "source.amazon-ebs.ubuntu-packer"
  ]

  provisioner "shell" {
    max_retries = 5
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
    ]
    // TODO: modify ssh port
    // TODO: security updates - via https://askubuntu.com/questions/194/how-can-i-install-just-security-updates-from-the-command-line
    inline = [
      "#!/bin/bash",
      "set -eux && sudo echo 'debconf debconf/frontend select Noninteractive' | sudo debconf-set-selections",
      "set -eux && sudo apt-get update -qq && sudo apt-get install -qq -y --no-install-recommends awscli unzip libssl-dev libgdiplus libc6-dev",
      // via https://stackoverflow.com/questions/72108697/when-i-open-unity-and-make-something-project-then-the-error-is-coming-that-no
      <<-EOT
        set -eux &&
        cd /tmp &&
        wget -q http://security.ubuntu.com/ubuntu/pool/main/o/openssl1.0/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb &&
        sudo apt-get install -qq -y --no-install-recommends /tmp/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb &&
        rm /tmp/libssl1.0.0_1.0.2n-1ubuntu5.10_amd64.deb &&
        cd -
      EOT
      ,
      // eco setup
      <<-EOT
        set -eux &&
        mkdir -p /home/ubuntu/games/eco &&
        cd /home/ubuntu/games/eco &&
        aws s3 cp s3://coilysiren-assets/downloads/EcoServerLinux . &&
        unzip -qq EcoServerLinux &&
        chmod a+x EcoServer
      EOT
      ,
    ]
  }
}
