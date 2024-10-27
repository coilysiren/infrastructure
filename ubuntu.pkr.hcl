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
  // latest x86 64 bit ubuntu LTS AMI from Canonical:
  // https://aws.amazon.com/marketplace/search/results?CREATOR=565feec9-3d43-413e-9760-c651546613f2&AMI_ARCHITECTURE=x86_64&REGION=us-east-1&FULFILLMENT_OPTION_TYPE=AMAZON_MACHINE_IMAGE&AMI_OPERATING_SYSTEM=UBUNTU&filters=CREATOR%2CAMI_ARCHITECTURE%2CREGION%2CFULFILLMENT_OPTION_TYPE%2CAMI_OPERATING_SYSTEM
  //
  // view subscription here:
  // https://us-east-1.console.aws.amazon.com/marketplace/home?region=us-east-1#/subscriptions
  source_ami            = "ami-011079f19d63f2405"
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
    sources = [
      "assets/",
    ]
    destination = "/tmp/"
  }

  provisioner "shell" {
    max_retries = 5
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
    ]
    script = "./scripts/ubuntu-setup.sh"
  }
}
