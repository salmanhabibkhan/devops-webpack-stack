variable "project_name" { type = string }
variable "vpc_id"       { type = string }
variable "subnet_ids"   { type = list(string) }
variable "targets"      { type = list(string) } # instance IDs
variable "target_port"  { type = number }
variable "internal"     { type = bool }
variable "health_path"  { type = string }