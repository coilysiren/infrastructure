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
  ami_name      = "ubuntu-packer"
  instance_type = "t3.micro"
  region        = "us-east-1"
  ssh_username  = "ubuntu"
  // latest free x86 64 bit ubuntu AMI from Canonical - https://aws.amazon.com/marketplace/search
  source_ami            = "ami-07d160315197aca8f"
  force_deregister      = true
  force_delete_snapshot = true
}

build {
  name = "ubuntu-packer"
  sources = [
    "source.amazon-ebs.ubuntu-packer"
  ]
}
