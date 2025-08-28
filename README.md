# Infrastructure: Private EC2 behind Internal NLB via API Gateway (VPC Link) with Custom Domain + ECR

This repository provisions production-ready AWS infrastructure that exposes a private EC2-hosted containerized app through API Gateway using a VPC Link to an internal Network Load Balancer. It also sets up DNS and TLS via Route 53 and ACM, and creates an ECR repository for your app images.

Architecture (high level)
```
Client
  │ HTTPS (custom domain)
  ▼
Route 53 (A/ALIAS) ──► API Gateway (HTTP API)
                          │ VPC Link (ENIs in private subnets)
                          ▼
                    Internal NLB (TCP:80)
                          ▼
                    EC2 (private) running Docker container
```

What gets created
- Networking
  - VPC with public and private subnets across 2 AZs
  - NAT Gateway for outbound internet from private subnets
- Compute
  - Private EC2 (no public IP) with:
    - Docker
    - SSM agent (managed instance)
    - CloudWatch Agent (collects container logs)
    - IAM instance profile with ECR read, SSM, CloudWatch
- Load Balancing
  - Internal NLB in private subnets, listener TCP:80
  - Target group health check on HTTP path /health
- API & Edge
  - API Gateway HTTP API with VPC Link to the NLB listener
  - Custom domain: web-api.<your-domain>
  - Route 53 A/ALIAS to API Gateway’s CloudFront target
  - ACM certificate (apex + wildcard) with DNS validation in Route 53
- Container Registry
  - ECR repository for the app (name = project_name, default web-api)
- Observability
  - API Gateway access log group
  - App container logs collected via CloudWatch Agent

Repository structure
```
.
├── versions.tf
├── providers.tf
├── variables.tf
├── main.tf
├── outputs.tf
├── terraform.tfvars.example
├── modules
│   ├── apigw
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   └── variables.tf
│   ├── ec2
│   │   ├── main.tf
│   │   └── variables.tf
│   ├── ecr
│   │   └── main.tf
│   ├── nlb
│   │   ├── main.tf
│   │   └── variables.tf
│   └── route53
│       ├── main.tf
│       └── variables.tf
```

Prerequisites
- A registered domain with a public Route 53 Hosted Zone (you must know its hosted zone ID).
- Terraform >= 1.6 and AWS provider ~> 5.60.
- AWS credentials configured locally with permission to create the above resources.
- Decide the AWS region (example uses us-east-1).

Configuration
- Copy terraform.tfvars.example to terraform.tfvars and set your values.

Example terraform.tfvars
```
aws_region     = "us-east-1"
project_name   = "web-api"
domain_name    = "salmnahabib.com"
hosted_zone_id = "ZXXXXXXXXXXXXXX"
```

Usage
1) Initialize and review
- terraform init -upgrade
- terraform validate
- terraform plan

2) Apply
- terraform apply
- Wait for ACM validation and DNS to propagate (usually a few minutes).

3) Outputs to note
- api_custom_domain: web-api.<domain_name>
- route53_record_fqdn: Fully-qualified DNS record created for the API
- ecr_repository_url: ECR repository URI
- nlb_dns_name: Internal NLB DNS (for debugging only; not public)

Accessing your API
- Public endpoint: https://web-api.your-domain/
- Health endpoint (proxied through to EC2): https://web-api.your-domain/health

Deploying the app (CI/CD)
- Use a separate application repository with a Dockerfile and a GitHub Actions workflow that:
  - Assumes an AWS IAM role via GitHub OIDC,
  - Builds and pushes to ECR,
  - Uses SSM SendCommand to pull and run the container on the EC2 instance(s) tagged App=web-api.

Minimal workflow outline
```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    aws-region: us-east-1
    role-to-assume: ${{ secrets.DEPLOY_ROLE_ARN }}

- uses: aws-actions/amazon-ecr-login@v2

- run: |
    docker build -t "$REG/web-api:latest" .
    docker push "$REG/web-api:latest"

- run: |
    aws ssm send-command \
      --document-name "AWS-RunShellScript" \
      --targets "Key=tag:App,Values=web-api" \
      --parameters commands="sudo bash -lc '
        aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.ap-south-1.amazonaws.com
        docker pull ${IMAGE_URI}
        docker rm -f web-api || true
        docker run -d --restart=always --name web-api -p 80:80 ${IMAGE_URI}
      '"
```

Important notes
- API Gateway VPC Link integration must use the NLB listener ARN as integration_uri. You do not use the NLB DNS name in API Gateway.
- The NLB is internal; the only public entry point is the API Gateway custom domain.
- The EC2 security group already allows TCP:80 from inside the VPC; NLB health checks hit /health on your container.

Logs & monitoring
- API Gateway access logs: /aws/apigwv2/<project_name>/access
- App container logs: /aws/ec2/web-api/app


Cleanup
- terraform destroy (removes all managed resources)

Security considerations
- EC2 instance profile grants minimum necessary for ECR read, SSM management, and CloudWatch logging.
- VPC Link SG is egress-only by default. You can restrict egress to only your VPC CIDRs for tighter control.
- Use GitHub OIDC with a role limited to your repo/branch for CI/CD (documented in DOCUMENTATION.md).

For a deep-dive guide (including CI role creation), see DOCUMENTATION.md.