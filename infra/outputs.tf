output "api_custom_domain" {
  value = module.apigw.api_gw_domain
}
output "route53_record_fqdn" {
  value = module.route53.record_fqdn
}
output "ecr_repository_url" {
  value = module.ecr.repository_url
}
output "ec2_instance_id" {
  value = module.ec2.instance_id
}
output "nlb_dns_name" {
  value = module.nlb.nlb_dns_name
}