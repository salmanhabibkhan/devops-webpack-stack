variable "project_name" {
  description = "Project/app name"
  type        = string
  default     = "web-api"
}

variable "aws_region" {
  description = "AWS region (e.g., us-east-1)"
  type        = string
}

variable "domain_name" {
  description = "Apex domain (e.g., salmanhabib.site)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the apex domain"
  type        = string
}