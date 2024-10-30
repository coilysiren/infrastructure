data "aws_route53_zone" "zone" {
  name = "coilysiren.me."
}


resource "aws_eip" "eip" {
  tags = {
    Name = var.name
  }
}

resource "aws_route53_record" "record_set" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "coilysiren.me."
  ttl     = 60
  type    = "A"
  records = [
    aws_eip.eip.id
  ]
}

resource "aws_ssm_parameter" "eip_param" {
  name  = "/cfn/${var.name}-${var.env}/eip-id"
  type  = "String"
  value = aws_eip.eip.id
}
