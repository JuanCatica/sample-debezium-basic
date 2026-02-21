# TO RUN:
# terraform init
# terraform plan
# terraform apply --auto-approve
# terraform dtroy --auto-approve
#es
# If destroy fails with "Configuration is in use", the cluster may still be
# deleting. Either wait and retry, or run in two phases:
#   1. terraform destroy -target=aws_msk_cluster.main --auto-approve  # wait ~45-60 min
#   2. terraform destroy --auto-approve
#
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
# Locals
# ---------------------------

locals {
  kafka_version   = "3.7.x"
  broker_nodes    = 2
  broker_instance = "kafka.t3.small" # Smallest instance for testing
  broker_ebs_size = 10               # GB - minimum for testing
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

# ---------------------------
# Security Group for MSK
# ---------------------------

resource "aws_security_group" "msk" {
  name        = "msk-${var.deployment_name}"
  description = "Security group for MSK cluster"
  vpc_id      = data.aws_vpc.main.id

  # Kafka broker - plaintext
  ingress {
    description = "Kafka plaintext"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Kafka broker - TLS
  ingress {
    description = "Kafka TLS"
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Kafka broker - IAM auth
  ingress {
    description = "Kafka IAM auth"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Zookeeper
  ingress {
    description = "Zookeeper"
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.main.cidr_block]
  }

  # Allow all outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "msk-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# CloudWatch Log Group for MSK
# ---------------------------

resource "aws_cloudwatch_log_group" "msk" {
  name              = "/aws/msk/${var.deployment_name}"
  retention_in_days = 7

  tags = {
    Name    = "msk-logs-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# MSK Configuration
# ---------------------------

resource "aws_msk_configuration" "debezium" {
  name           = "msk-config-${var.deployment_name}"
  kafka_versions = [local.kafka_version]
  description    = "MSK configuration optimized for Debezium"

  server_properties = <<PROPERTIES
auto.create.topics.enable=true
delete.topic.enable=true
default.replication.factor=2
min.insync.replicas=1
num.partitions=3
log.retention.hours=24
log.retention.bytes=1073741824
PROPERTIES
}

# ---------------------------
# MSK Cluster
# ---------------------------

resource "aws_msk_cluster" "main" {
  depends_on             = [aws_msk_configuration.debezium]
  cluster_name           = "msk-${var.deployment_name}"
  kafka_version          = local.kafka_version
  number_of_broker_nodes = local.broker_nodes

  # MSK cluster deletion is asynchronous (30-60 min). Must wait for full
  # deletion before Terraform can destroy the configuration.
  timeouts {
    create = "2h"
    update = "2h"
    delete = "90m"
  }

  broker_node_group_info {
    instance_type   = local.broker_instance
    client_subnets  = slice(data.aws_subnets.private.ids, 0, local.broker_nodes)
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = local.broker_ebs_size
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.debezium.arn
    revision = aws_msk_configuration.debezium.latest_revision
  }

  # Enable IAM authentication for MSK Connect
  client_authentication {
    unauthenticated = true
    sasl {
      iam = true
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = true
    }
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk.name
      }
    }
  }

  tags = {
    Name    = "msk-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# SSM Parameters (for notebook /kafka/*)
# ---------------------------

resource "aws_ssm_parameter" "bootstrap_servers" {
  name  = "/kafka/bootstrap_servers"
  type  = "String"
  value = aws_msk_cluster.main.bootstrap_brokers

  tags = {
    Name        = "kafka-bootstrap-${var.deployment_name}"
    Environment = var.deployment_name
  }
}

# ---------------------------
# Outputs
# ---------------------------

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.main.arn
}

output "msk_cluster_name" {
  description = "Name of the MSK cluster"
  value       = aws_msk_cluster.main.cluster_name
}

output "msk_bootstrap_brokers" {
  description = "Plaintext bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers
}

output "msk_bootstrap_brokers_tls" {
  description = "TLS bootstrap brokers"
  value       = aws_msk_cluster.main.bootstrap_brokers_tls
}

output "msk_bootstrap_brokers_iam" {
  description = "IAM bootstrap brokers (for MSK Connect)"
  value       = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
}

output "msk_zookeeper_connect_string" {
  description = "Zookeeper connection string"
  value       = aws_msk_cluster.main.zookeeper_connect_string
}

output "msk_security_group_id" {
  description = "Security group ID for MSK"
  value       = aws_security_group.msk.id
}
