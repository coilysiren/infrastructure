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

  provisioner "file" {
    source      = "assets/eco-server.service"
    destination = "/tmp/eco-server.service"
  }

  provisioner "file" {
    source      = "requirements.txt"
    destination = "/tmp/requirements.txt"
  }

  provisioner "file" {
    source      = "tasks.py"
    destination = "/tmp/tasks.py"
  }

  provisioner "shell" {
    max_retries = 5
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
    ]
    script = "./scripts/ubuntu-install.sh"
  }
}
