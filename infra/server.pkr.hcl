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

source "amazon-ebs" "windows-packer" {
  // Miscrosoft Windows Server 2022 Base
  // https://aws.amazon.com/marketplace/search/results?AMI_ARCHITECTURE=x86_64&REGION=us-east-1&AMI_OPERATING_SYSTEM=WIN_2022&FULFILLMENT_OPTION_TYPE=AMAZON_MACHINE_IMAGE&CREATOR=e6a5002c-6dd0-4d1e-8196-0a1d1857229b&filters=AMI_ARCHITECTURE%2CREGION%2CAMI_OPERATING_SYSTEM%2CFULFILLMENT_OPTION_TYPE%2CCREATOR
  //
  // view subscriptions here:
  // https://us-east-1.console.aws.amazon.com/servicecatalog/home?region=us-east-1#admin-products
  source_ami            = "ami-0324a83b82023f0b3"
  ami_name              = "windows-packer"
  user_data_file        = "./templates/bootstrap.txt"
  winrm_username        = "admin"
  communicator          = "winrm"
  instance_type         = "t3.micro"
  region                = "us-east-1"
  force_deregister      = true
  force_delete_snapshot = true
  iam_instance_profile  = "game-server"
}

build {
  name    = "windows-packer"
  sources = ["amazon-ebs.windows-packer"]

  provisioner "file" {
    sources = [
      "C:\\Program Files (x86)\\Steam\\steamapps\\common\\Steamworks Shared\\_CommonRedist\\vcredist\\2022\\VC_redist.x64.exe",
    ]
    destination = "."
  }

  provisioner "powershell" {
    inline = ["VC_redist.x64.exe /quiet"]
  }
}
