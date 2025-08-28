module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project     = var.project_name
    Environment = "dev"
    Terraform   = "true"
  }
}

module "ecr" {
  source       = "./modules/ecr"
  project_name = var.project_name
}

module "ec2" {
  source       = "./modules/ec2"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_id    = module.vpc.private_subnets[0]
  vpc_cidr     = module.vpc.vpc_cidr_block
}

module "nlb" {
  source       = "./modules/nlb"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnets
  targets      = [module.ec2.instance_id]
  target_port  = 80
  internal     = true
  health_path  = "/health"
}

module "apigw" {
  source             = "./modules/apigw"
  project_name       = var.project_name
  domain_name        = var.domain_name
  hosted_zone_id     = var.hosted_zone_id
  private_subnet_ids = module.vpc.private_subnets
  nlb_listener_arn   = module.nlb.listener_arn
  vpc_id             = module.vpc.vpc_id   
}

module "route53" {
  source            = "./modules/route53"
  domain_name       = var.domain_name
  hosted_zone_id    = var.hosted_zone_id
  api_gw_cf_target  = module.apigw.api_gw_cf_target
  api_gw_cf_zone_id = module.apigw.api_gw_cf_zone_id
}