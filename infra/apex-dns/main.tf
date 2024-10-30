data "aws_route53_zone" "zone" {
  name = "coilysiren.me."
}

resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "coilysiren.me."
  ttl     = 60
  type    = "A"
  records = [
    "75.2.60.5"
  ]
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "coilysiren.me."
  ttl     = 60
  type    = "CNAME"
  records = [
    "coilysiren-dot-me.netlify.app."
  ]
}
