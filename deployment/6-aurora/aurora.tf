# TO RUN:
# terraform init
# terraform plan
# terraform apply -var="deployment_name=<nombre>"
# terraform destroy -var="deployment_name=<nombre>"
#
# Requisitos previos: 1-vpc desplegado (para VPC, subnets, etc.)
#
# Aurora MySQL como target/sink para CDC (Debezium Oracle -> Kafka -> Aurora)

# -------------------------------------------------------------
# Aurora Instance Types (Reference)
#
# Instance Type    vCPUs   RAM (GiB)
# --------------   ------  ----------
# db.t3.medium        2         4
# db.t4g.medium       2         4   (Graviton, menor costo)
# db.r6g.large        2        16
# db.r6g.xlarge       4        32
# -------------------------------------------------------------

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
  aurora_username       = "admin"
  aurora_password       = "changeme123"
  aurora_port            = 3306
  aurora_instance_class = "db.t4g.medium" # Graviton, cost-effective
  aurora_database_name   = "auroradb"
}

# ---------------------------
# Variables
# ---------------------------

variable "deployment_name" {
  type        = string
  description = "Deployment name (debe coincidir con 1-vpc)"
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

# ---------------------------
# Security Group
# ---------------------------

resource "aws_security_group" "aurora" {
  name        = "aurora-${var.deployment_name}"
  description = "Allow MySQL traffic to Aurora"
  vpc_id      = data.aws_vpc.main.id

  ingress {
    description = "MySQL/Aurora"
    from_port   = local.aurora_port
    to_port     = local.aurora_port
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "aurora-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# DB Subnet Group
# ---------------------------

resource "aws_db_subnet_group" "aurora" {
  name       = "aurora-subnet-group-${var.deployment_name}"
  subnet_ids = data.aws_subnets.private.ids

  tags = {
    Name    = "aurora-subnet-group-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# IAM Role for Enhanced Monitoring
# ---------------------------

resource "aws_iam_role" "aurora_enhanced_monitoring" {
  name = "aurora-enhanced-monitoring-${var.deployment_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "aurora-enhanced-monitoring-${var.deployment_name}"
    project = "debezium"
  }
}

resource "aws_iam_role_policy_attachment" "aurora_enhanced_monitoring" {
  role       = aws_iam_role.aurora_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------
# Aurora Cluster
# ---------------------------

resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "aurora-${var.deployment_name}"
  engine                 = "aurora-mysql"
  engine_mode            = "provisioned"
  engine_version         = "8.0.mysql_aurora.3.08.2"
  database_name          = local.aurora_database_name
  master_username        = local.aurora_username
  master_password        = local.aurora_password
  port                   = local.aurora_port

  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]

  backup_retention_period = 7
  preferred_backup_window  = "03:00-04:00"
  skip_final_snapshot     = true
  apply_immediately      = true

  enabled_cloudwatch_logs_exports = ["audit", "error", "general", "slowquery"]

  tags = {
    Name    = "aurora-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# Aurora Cluster Instance (Writer)
# ---------------------------

resource "aws_rds_cluster_instance" "aurora" {
  depends_on = [aws_iam_role_policy_attachment.aurora_enhanced_monitoring]

  identifier         = "aurora-${var.deployment_name}-instance-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = local.aurora_instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  monitoring_interval = 60
  monitoring_role_arn = aws_iam_role.aurora_enhanced_monitoring.arn

  performance_insights_enabled = true
  performance_insights_retention_period = 7

  tags = {
    Name    = "aurora-${var.deployment_name}-instance-1"
    project = "debezium"
  }
}

# ---------------------------
# SSM Parameters (for notebooks /aurora/*)
# ---------------------------

resource "aws_ssm_parameter" "aurora_host" {
  name  = "/aurora/host"
  type  = "String"
  value = aws_rds_cluster.aurora.endpoint

  tags = {
    Name        = "aurora-host-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_ssm_parameter" "aurora_reader_host" {
  name  = "/aurora/reader_host"
  type  = "String"
  value = aws_rds_cluster.aurora.reader_endpoint

  tags = {
    Name        = "aurora-reader-host-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_ssm_parameter" "aurora_port" {
  name  = "/aurora/port"
  type  = "String"
  value = tostring(aws_rds_cluster.aurora.port)

  tags = {
    Name        = "aurora-port-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_ssm_parameter" "aurora_user" {
  name  = "/aurora/user"
  type  = "String"
  value = aws_rds_cluster.aurora.master_username

  tags = {
    Name        = "aurora-user-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_ssm_parameter" "aurora_password" {
  name  = "/aurora/password"
  type  = "SecureString"
  value = local.aurora_password

  tags = {
    Name        = "aurora-password-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

resource "aws_ssm_parameter" "aurora_database" {
  name  = "/aurora/database"
  type  = "String"
  value = aws_rds_cluster.aurora.database_name

  tags = {
    Name        = "aurora-database-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

# ---------------------------
# Outputs
# ---------------------------

output "aurora_cluster_endpoint" {
  description = "Writer endpoint (use for writes)"
  value       = aws_rds_cluster.aurora.endpoint
}

output "aurora_reader_endpoint" {
  description = "Reader endpoint (use for read replicas)"
  value       = aws_rds_cluster.aurora.reader_endpoint
}

output "aurora_port" {
  description = "Aurora port"
  value       = aws_rds_cluster.aurora.port
}

output "aurora_database_name" {
  description = "Database name"
  value       = aws_rds_cluster.aurora.database_name
}

output "aurora_username" {
  description = "Master username"
  value       = aws_rds_cluster.aurora.master_username
}

output "aurora_password" {
  description = "Master password"
  value       = local.aurora_password
  sensitive   = true
}

output "aurora_jdbc_url" {
  description = "JDBC URL for writer"
  value       = "jdbc:mysql://${aws_rds_cluster.aurora.endpoint}:${aws_rds_cluster.aurora.port}/${aws_rds_cluster.aurora.database_name}"
}

output "aurora_connection_string" {
  description = "Connection string for MySQL client"
  value       = "${aws_rds_cluster.aurora.endpoint}:${aws_rds_cluster.aurora.port}/${aws_rds_cluster.aurora.database_name}"
}
