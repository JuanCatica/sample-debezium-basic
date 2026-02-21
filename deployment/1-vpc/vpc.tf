# TO RUN:
# terraform init
# terraform plan
# terraform apply --auto-approve
# terraform destroy --auto-approve
# rm -rf .terraform.lock.hcl .terraform terraform.tfstate

terraform {
  required_version = ">= 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# ---------------------------
# Variables
# ---------------------------

variable "deployment_name" {
  type        = string
  description = "Deployment name"
}

# ---------------------------
# Data Sources
# ---------------------------

data "aws_region" "current" {}

# ---------------------------
# VPC
# ---------------------------

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "vpc-${var.deployment_name}"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = false
  enable_vpn_gateway = false

  # Enable DNS hostnames and DNS resolution for VPC endpoints
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
  }
}

# ---------------------------
# Security Group for VPC Endpoints
# ---------------------------

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "vpc-endpoints-${var.deployment_name}"
  vpc_id      = module.vpc.vpc_id

  # Allow HTTPS traffic from private subnets (where ECS tasks run)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = module.vpc.private_subnets_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "vpc-endpoints-${var.deployment_name}"
  }
}

# Security Group for ECS Tasks
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "ecs-tasks-${var.deployment_name}"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow all other outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-tasks-${var.deployment_name}"
  }
}

resource "aws_security_group" "alb_sg" {
  name = "alb-${var.deployment_name}"

  vpc_id = module.vpc.vpc_id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-${var.deployment_name}"
  }
}

# ---------------------------
# VPC Endpoints for ECR
# ---------------------------

module "endpoints" {
  source = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  endpoints = {
    # ECR API endpoint (required for authentication)
    ecr_api = {
      service             = "ecr.api"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "ecr-api-endpoint-${var.deployment_name}" }
    }

    # ECR DKR endpoint (required for pulling images)
    ecr_dkr = {
      service             = "ecr.dkr"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "ecr-dkr-endpoint-${var.deployment_name}" }
    }

    # CloudWatch Logs endpoint (optional, for better logging)
    logs = {
      service             = "logs"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "logs-endpoint-${var.deployment_name}" }
    }

    # Secrets Manager - required for MSK Connect config provider (Oracle credentials)
    secretsmanager = {
      service             = "secretsmanager"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "secretsmanager-endpoint-${var.deployment_name}" }
    }

    # STS - required for MSK Connect IAM authentication to Kafka cluster
    sts = {
      service             = "sts"
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "sts-endpoint-${var.deployment_name}" }
    }
  }
}

# ---------------------------
# S3 Gateway Endpoint
# ---------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.id}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = module.vpc.private_route_table_ids

  tags = {
    Name = "s3-gateway-endpoint-${var.deployment_name}"
  }
}