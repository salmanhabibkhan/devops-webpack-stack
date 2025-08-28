variable "project_name"       { type = string }
variable "domain_name"        { type = string }
variable "hosted_zone_id"     { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "nlb_listener_arn"   { type = string }
variable "vpc_id"             { type = string }  # NEW