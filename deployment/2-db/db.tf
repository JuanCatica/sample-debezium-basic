# TO RUN:
# terraform init
# terraform plan
# terraform apply --auto-approve
# terraform destroy --auto-approve
# rm -rf .terraform.lock.hcl .terraform terraform.tfstate

# habilitar LogMiner para CDC
# ALTER DATABASE ARCHIVELOG;
# ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
# ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

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
# Locals
# ---------------------------

locals {
  source_db_username       = "admin"
  source_db_password       = "changeme123"
  source_db_port           = 1521
  source_rds_instance_type = "db.t3.small"
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

# ---------------------------
# Security Group
# ---------------------------

resource "aws_security_group" "allow_public_source" {
  name        = "allow-public-source-${var.deployment_name}"
  description = "Allow inbound traffic to Oracle RDS"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "Oracle port"
    from_port   = local.source_db_port
    to_port     = local.source_db_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "allow-public-source-${var.deployment_name}"
    project = "oracle2aurora"
  }
}

# ---------------------------
# RDS Instance
# ---------------------------

resource "aws_db_instance" "oracle_source" {
  identifier     = "oracledb-source-${var.deployment_name}"
  instance_class = local.source_rds_instance_type
  engine         = "oracle-se2"
  engine_version = "19.0.0.0.ru-2023-01.rur-2023-01.r1" #"19.0.0.0"#"12.2.0.1.ru-2018-10.rur-2018-10.r1"
  license_model  = "license-included"

  storage_type                    = "gp2"
  allocated_storage               = 20
  max_allocated_storage           = 25
  multi_az                        = false
  db_name                         = "DBSOURCE"
  username                        = local.source_db_username
  password                        = local.source_db_password
  port                            = local.source_db_port
  skip_final_snapshot             = true
  apply_immediately               = true
  publicly_accessible             = true
  db_subnet_group_name            = aws_db_subnet_group.subnet_group_source.name
  vpc_security_group_ids          = [aws_security_group.allow_public_source.id]
  enabled_cloudwatch_logs_exports = ["alert", "audit", "listener", "trace"]
  backup_retention_period         = 1
  monitoring_interval             = 0

  tags = {
    Name = "oracle_source-${var.deployment_name}"
  }
}

resource "aws_db_subnet_group" "subnet_group_source" {
  name       = "subnet-group-source"
  subnet_ids = data.aws_subnets.public.ids

  tags = {
    Name    = "subnet_group_source"
    project = "oracle2aurora"
  }
}


# ---------------------------
# Outputs for DataGrip Connection
# ---------------------------

output "rds_engine_version_actual" {
  description = "Actual engine version"
  value       = aws_db_instance.oracle_source.engine_version_actual
}

output "rds_endpoint" {
  description = "RDS endpoint (host)"
  value       = aws_db_instance.oracle_source.address
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.oracle_source.port
}

output "rds_database_name" {
  description = "Database name (SID)"
  value       = aws_db_instance.oracle_source.db_name
}

output "rds_username" {
  description = "Database username"
  value       = aws_db_instance.oracle_source.username
}

output "rds_password" {
  description = "Database password"
  value       = local.source_db_password
  sensitive   = true
}

output "rds_jdbc_url" {
  description = "JDBC URL for DataGrip"
  value       = "jdbc:oracle:thin:@${aws_db_instance.oracle_source.address}:${aws_db_instance.oracle_source.port}:${aws_db_instance.oracle_source.db_name}"
}

output "rds_connection_string" {
  description = "Easy connect string for SQL*Plus/DataGrip"
  value       = "${aws_db_instance.oracle_source.address}:${aws_db_instance.oracle_source.port}/${aws_db_instance.oracle_source.db_name}"
}