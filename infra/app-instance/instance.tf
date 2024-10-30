resource "aws_ec2_instance_state" "instance" {
  instance_id = var.instance_type
  // CF Property(PropagateTagsToVolumeOnCreation) = true
  // CF Property(SecurityGroupIds) = var.security_groups
  // CF Property(KeyName) = var.key_name
  // CF Property(ImageId) = var.ami
  // CF Property(SubnetId) = var.subnet
  // CF Property(UserData) = base64encode("#!/bin/bash
  // set -eux
  // sudo chmod 777 /var/log/
  // sudo chown -R ubuntu /var/log/
  // exec > >(tee /var/log/user-data-1.log|logger -t user-data -s 2>/var/log/user-data-2.log) 2>&1
  //   echo 'export ENV=${var.env}' sponge -a /home/ubuntu/.bashrc
  //   aws ecr get-login-password | docker login -u AWS --password-stdin "${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com"
  //   docker pull "${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/${var.service}-ecr:${var.env}"
  //   mkdir -p /home/ubuntu/data
  //   sudo mount /dev/nvme1n1 /home/ubuntu/data
  //   mkdir -p /home/ubuntu/data/storage
  //   mkdir -p /home/ubuntu/data/logs
  //   sudo chown -R ubuntu /home/ubuntu/data
  //   sudo blkid -o export /dev/nvme1n1
  //   echo "$(sudo blkid -o export /dev/nvme1n1 | grep ^UUID=) /home/ubuntu/data ext4 defaults,noatime" | sudo tee -a /etc/fstab
  //   sudo systemctl enable ${var.service}
  //   sudo systemctl start ${var.service}
  // ")
  // CF Property(tags) = {
  //   Name = var.name
  // }
}

resource "aws_eip_association" "eip_association" {
  allocation_id = var.eip_allocation_id
  instance_id   = aws_ec2_instance_state.instance.id
}

resource "aws_volume_attachment" "volume_attachment" {
  instance_id = aws_ec2_instance_state.instance.id
  volume_id   = var.volume
  device_name = "sdg"
}
