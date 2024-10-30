resource "aws_ebs_volume" "volume" {
  size              = 10
  availability_zone = "us-east-1c"
  tags = {
    Name = var.name
  }
}
