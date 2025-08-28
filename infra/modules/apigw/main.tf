resource "aws_apigatewayv2_api" "http_api" {
  name          = var.project_name
  protocol_type = "HTTP"
}

# Security group for API Gateway VPC Link ENIs (egress-only)
resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-apigw-vpc-link-sg"
  description = "SG for API Gateway VPC Link ENIs"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-apigw-vpc-link-sg"
  }
}

# VPC Link into private subnets (must include security_group_ids)
resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project_name}-vpc-link"
  subnet_ids         = var.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

# Integration must use the NLB LISTENER ARN
resource "aws_apigatewayv2_integration" "nlb" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "HTTP_PROXY"
  integration_uri        = var.nlb_listener_arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  payload_format_version = "1.0"
  integration_method     = "ANY"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.nlb.id}"
}

# CloudWatch access logs
resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigwv2/${var.project_name}/access"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId  = "$context.requestId",
      httpMethod = "$context.httpMethod",
      path       = "$context.path",
      status     = "$context.status",
      routeKey   = "$context.routeKey",
      ip         = "$context.identity.sourceIp",
      ua         = "$context.identity.userAgent",
      integErr   = "$context.integrationErrorMessage"
    })
  }
}

# ACM cert for apex + wildcard (DNS validated via Route53)
resource "aws_acm_certificate" "cert" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]

  # Add this line so Terraform can update an existing validation record
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

# API Gateway custom domain and mapping
resource "aws_apigatewayv2_domain_name" "custom" {
  domain_name = "web-api.${var.domain_name}"
  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.cert.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "mapping" {
  api_id      = aws_apigatewayv2_api.http_api.id
  domain_name = aws_apigatewayv2_domain_name.custom.domain_name
  stage       = aws_apigatewayv2_stage.default.name
}