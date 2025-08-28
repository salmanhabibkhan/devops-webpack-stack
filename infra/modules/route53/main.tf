resource "aws_route53_record" "api_gw_alias" {
  zone_id = var.hosted_zone_id
  name    = "web-api.${var.domain_name}"
  type    = "A"
  alias {
    name                   = var.api_gw_cf_target
    zone_id                = var.api_gw_cf_zone_id
    evaluate_target_health = false
  }
}

output "record_fqdn" {
  value = aws_route53_record.api_gw_alias.fqdn
}