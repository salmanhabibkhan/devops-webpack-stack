# Full Infrastructure Guide

This document explains the architecture, components, configuration, CI/CD integration, operations, and troubleshooting for this Terraform-based infrastructure.

Contents
- 1. Architecture overview
- 2. Components and modules
- 3. Configuration and variables
- 4. Provisioning workflow
- 5. CI/CD deployment workflow (app repo)
- 6. Operations (day-2)
- 7. Troubleshooting
- 8. Security model
- 9. Cost considerations
- 10. Common customizations

---

1) Architecture overview
- Goal: Run a containerized web API on a private EC2 instance, reachable publicly via a custom domain over HTTPS, without exposing EC2 to the internet.
- Pattern:
  - API Gateway (HTTP API) provides the public HTTPS endpoint with TLS and custom domain.
  - API Gateway connects to an internal Network Load Balancer via a VPC Link.
  - The NLB targets the EC2 instance(s) on TCP:80.
  - Route 53 provides DNS (A/ALIAS) pointing to API Gateway’s CloudFront target.
  - ACM provides the TLS certificate (DNS validated).
  - ECR stores the application container image.

ASCII diagram
```
Internet
  │
  ▼
DNS (Route 53 A/ALIAS: web-api.<domain>) ──► API Gateway (HTTP API)
                                                │ VPC Link (ENIs in private subnets)
                                                ▼
                                        NLB (internal TCP:80)
                                                ▼
                                        EC2 (private) + Docker
                                                  └─ container listens on :80 (/health)
```

Key decisions
- Use HTTP API (apigatewayv2) for simplicity and cost efficiency.
- VPC Link targets the NLB listener ARN (required by apigatewayv2 HTTP_PROXY integration).
- NLB is internal; EC2 remains private (no public IP).
- CI/CD deploys via SSM; no SSH required.

---

2) Components and modules

Root
- versions.tf: Terraform and provider versions.
- providers.tf: AWS provider region configuration.
- variables.tf: Inputs for region, domain, hosted zone, project name.
- main.tf: Wires modules together (VPC → EC2 → NLB → API Gateway → Route 53).
- outputs.tf: Exposes key outputs.
- terraform.tfvars.example: Sample values.

Module: VPC (terraform-aws-modules/vpc)
- Two AZs, public/private subnets.
- Single NAT gateway for outbound from private subnets.

Module: EC2 (modules/ec2)
- Amazon Linux 2023 AMI.
- User data installs Docker and CloudWatch Agent.
- Instance profile:
  - AmazonSSMManagedInstanceCore (SSM management)
  - AmazonEC2ContainerRegistryReadOnly (pull images from ECR)
  - CloudWatchAgentServerPolicy (send logs)
- Security group:
  - Ingress TCP:80 from VPC CIDR (allows NLB-to-EC2).
  - Egress: all.
- Tag App=web-api (used by CI to target instances via SSM).

Module: NLB (modules/nlb)
- Internal NLB in private subnets.
- Listener TCP:80.
- Target group with HTTP health check on /health (port: traffic-port).
- Attach EC2 instance(s).
- Outputs listener ARN (used by API Gateway integration).

Module: API Gateway (modules/apigw)
- apigatewayv2 HTTP API.
- VPC Link across private subnets; includes security_group_ids (egress SG).
- HTTP_PROXY integration to NLB listener (integration_uri = listener ARN).
- Route ANY /{proxy+} → proxies all paths.
- Stage $default with access logging.
- ACM certificate:
  - Domain: apex, SAN: wildcard (*.domain)
  - DNS validation in Route 53; records allow_overwrite = true
- Custom domain: web-api.<domain>
- API mapping to $default stage.

Module: Route 53 (modules/route53)
- A/ALIAS record: web-api.<domain> → API Gateway regional domain (CloudFront target and zone ID from apigw module outputs).

Module: ECR (modules/ecr)
- Repository named after project_name (default web-api).
- Scan-on-push enabled; AES256 at rest.
- Outputs repository URL (and ARN if you extended it).

Important notes
- You never use the NLB DNS in API Gateway; use the NLB Listener ARN for integration_uri.
- The VPC Link creates ENIs in your private subnets; it needs a security group (egress-only is sufficient by default).

---

3) Configuration and variables

Core variables (variables.tf)
- aws_region: AWS region (e.g., us-east-1)
- project_name: Used to name ECR repo, tags, etc. Default: web-api
- domain_name: Your apex domain (e.g., salmanhabib.com) — must have a public hosted zone in Route 53
- hosted_zone_id: Hosted Zone ID for the apex domain

Sample terraform.tfvars
```
aws_region     = "us-east-1"
project_name   = "web-api"
domain_name    = "example.com"
hosted_zone_id = "XXXXXXXXXXXXXX"
```

---

4) Provisioning workflow

Steps
1) terraform init -upgrade
2) terraform validate
3) terraform plan
4) terraform apply

Post-apply
- ACM will validate automatically using DNS records created by Terraform.
- Once the API Gateway custom domain is issued and DNS propagates, your endpoint will be available at:
  - https://web-api.domain/
  - https://web-api.domain/health

Outputs to capture
- api_custom_domain
- route53_record_fqdn
- ecr_repository_url
- nlb_dns_name (debugging only)

---

5) CI/CD deployment workflow (app repo)

Separation
- Keep application code and CI separate from infra. This infra repo creates the ECR repo and target environment; the app repo handles build/deploy.

Minimal requirements in app repo
- Dockerfile to build an image that listens on 0.0.0.0:80 and serves GET /health with 200.
- GitHub Actions workflow that:
  - Configures AWS credentials via GitHub OIDC,
  - Logs in to ECR,
  - Builds and pushes the image,
  - Sends an SSM command to EC2 instances tagged App=web-api to pull and run the container.

GitHub OIDC IAM role (one-time)
- Create a role in AWS IAM trusted by token.actions.githubusercontent.com with a sub claim:
  - repo:<owner>/<repo>:ref:refs/heads/main
- Permissions attached:
  - ECR push/pull (GetAuthorizationToken, PutImage, Batch*, Describe*)
  - SSM SendCommand to document AWS-RunShellScript and to instances with tag App=web-api
- Put the role ARN into your app repo secret: DEPLOY_ROLE_ARN
- Example trust policy and permissions are documented in the README and below troubleshooting appendix.

Example deployment command executed via SSM
```
aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --targets "Key=tag:App,Values=web-api" \
  --parameters commands="sudo bash -lc '
    aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com
    docker pull <account>.dkr.ecr.<region>.amazonaws.com/web-api:latest
    docker rm -f web-api || true
    docker run -d --restart=always --name web-api -p 80:80 <account>.dkr.ecr.<region>.amazonaws.com/web-api:latest
  '"
```

---

6) Operations (day-2)

Observability
- API Gateway access logs: /aws/apigwv2/<project_name>/access
- App logs (from Docker JSON) via CloudWatch Agent: /aws/ec2/web-api/app

Health checks
- Target group health should be healthy after the app is deployed.
- API endpoint /health should return 200 via API Gateway.

Maintenance
- To update the app, push a new image via CI; SSM will redeploy.
- To scale out, add more private EC2 instances and attach them to the target group, or migrate to ECS Fargate and point the VPC Link to an internal ALB/NLB.

Backups and state
- Recommended: Use a remote Terraform backend (S3 + DynamoDB lock). This repo currently uses the local backend; consider adding:
  - backend "s3" with a DynamoDB lock table.

---

7) Troubleshooting

Provisioning-time issues seen and fixes
- Duplicate output definition in apigw:
  - Keep outputs only in modules/apigw/outputs.tf; remove duplicates from main.tf.
- HCL syntax errors (semicolons, single-line blocks):
  - Do not use semicolons; expand nested blocks to multi-line.
  - Use proper heredoc syntax for user_data (<<-EOT ... EOT), not single-quoted markers.
- VPC Link requires security_group_ids:
  - Ensure modules/apigw defines a security group and passes its ID to aws_apigatewayv2_vpc_link.
- for_each unknown values for target_group_attachment:
  - Use count = length(var.targets) and index into var.targets; avoids unknown-key planning issue.
- ACM validation record already exists:
  - Set allow_overwrite = true on aws_route53_record for ACM validation.

Runtime issues
- NLB targets unhealthy:
  - Ensure container listens on 0.0.0.0:80 and /health returns 200.
  - Confirm EC2 SG allows TCP:80 from VPC CIDR (it does by default in this repo).
- API Gateway 502/504:
  - VPC Link must be Available.
  - NLB target group must be healthy.
  - Integration URI must be the NLB Listener ARN (not DNS).
- SSM command failures:
  - Instance must be “Managed” in Systems Manager (check IAM instance profile).
  - Instance needs outbound internet (NAT) or SSM VPC endpoints (NAT is provided here).
- DNS/TLS:
  - ACM certificate must be Issued; Route 53 validation CNAMEs must exist.
  - DNS propagation can take a few minutes.

Diagnostics
- Check API Gateway access logs for status codes and integration errors.
- Check CloudWatch app log group for container logs.
- Use: aws elbv2 describe-target-health --target-group-arn <arn> for precise health reasons.

---

8) Security model

- EC2 instance profile:
  - AmazonSSMManagedInstanceCore: managed by SSM.
  - AmazonEC2ContainerRegistryReadOnly: pull images from ECR (no push from instance).
  - CloudWatchAgentServerPolicy: send logs only.
- API Gateway VPC Link SG:
  - Egress-only; can be restricted to VPC CIDR or specific subnets.
- No inbound rules from the internet to EC2; access only through NLB inside VPC.
- API Gateway serves HTTPS via ACM-issued cert for your domain.

CI/CD access (recommended)
- Use GitHub OIDC to assume a narrowly scoped role from your app repo’s main branch.
- Restrict SSM commands to instances with tag App=web-api.

---

9) Cost considerations

- NAT Gateway: billed hourly + data processing; main cost driver in dev environments.
- API Gateway HTTP API: per-request pricing (cheaper than REST API).
- NLB: hourly + LCU usage.
- EC2: instance hourly; choose t3.micro for test.
- CloudWatch logs: ingestion + storage (set retention appropriately).
- ACM + Route 53: ACM free for public certs; Route 53 hosted zone + queries billed.
---

10) Common customizations

- Use an S3 backend for Terraform state
  - Add a backend "s3" block and a DynamoDB lock table for team workflows.
