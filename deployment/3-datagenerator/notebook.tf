# TO RUN:
# terraform init
# terraform plan
# terraform apply --auto-approve
# terraform destroy --auto-approve
# rm -rf .terraform.lock.hcl .terraform terraform.tfstate

# -------------------------------------------------------------
# SageMaker Notebook Instance Types (Reference Table)
#
# Instance Type       vCPUs   RAM (GiB)
# --------------      ------  ----------
# ml.t3.medium        2         4
# ml.t3.large         2         8
# ml.t3.xlarge        4        16
# -------------------------------------------------------------

terraform {
  required_version = ">= 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}


# ---------------------------
# Locals
# ---------------------------

locals {
  instance_type = "ml.t3.large" 
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

data "aws_caller_identity" "current" {}

data "aws_vpc" "main" {
  tags = {
    Name = "vpc-${var.deployment_name}"
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.deployment_name}-private-*"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.deployment_name}-public-*"]
  }
}

# -------------------------------------
# Security Group
# -------------------------------------

resource "aws_security_group" "datagen_notebook_sg" {
  name        = "datagen-notebook-${var.deployment_name}"
  description = "Security group for SageMaker data generator notebook"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "HTTPS for Jupyter"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound (internet, RDS, SageMaker APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "datagen-notebook-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

# -------------------------------------
# Code Repository (Git)
# -------------------------------------

resource "aws_sagemaker_code_repository" "sample_debezium" {
  code_repository_name = "sample-debezium-basic-${var.deployment_name}"

  git_config {
    repository_url = "https://github.com/JuanCatica/sample-debezium-basic.git"
  }
}

# -------------------------------------
# Notebook
# -------------------------------------

resource "aws_sagemaker_notebook_instance" "datagen_notebook" {
  name                     = "datagen-notebook-${var.deployment_name}"
  instance_type            = local.instance_type
  role_arn                 = aws_iam_role.sagemaker_notebook_role.arn
  subnet_id                = data.aws_subnets.public.ids[0]
  security_groups          = [aws_security_group.datagen_notebook_sg.id]
  default_code_repository  = aws_sagemaker_code_repository.sample_debezium.code_repository_name

  tags = {
    Name        = "datagen-notebook-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_iam_role" "sagemaker_notebook_role" {
  name = "sagemaker-notebook-role-${var.deployment_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_notebook_AmazonSageMakerFullAccess" {
  role       = aws_iam_role.sagemaker_notebook_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "sagemaker_notebook_AmazonS3ReadOnlyAccess" {
  role       = aws_iam_role.sagemaker_notebook_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "sagemaker_notebook_CloudWatchLogs" {
  role       = aws_iam_role.sagemaker_notebook_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy" "sagemaker_notebook_ssm" {
  name = "sagemaker-notebook-ssm-${var.deployment_name}"
  role = aws_iam_role.sagemaker_notebook_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = [
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/dbhost",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/dbport",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/dbuser",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/dbpass",
          "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/dbname"
        ]
      }
    ]
  })
}
