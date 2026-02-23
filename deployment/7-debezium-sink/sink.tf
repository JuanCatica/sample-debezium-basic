# MSK Connect + Debezium JDBC Sink
#
# Consumes from Kafka topic oracle-cdc.ADMIN.TAGS (Debezium CDC events)
# and writes to Aurora PostgreSQL.
#
# Requisitos previos:
# 1. Ejecutar deployment 1-vpc, 4-kafka, 5-debezium-cdc, 6-aurora
# 2. El connector Debezium Oracle (5-debezium-cdc) debe estar RUNNING y haber creado el topic
# 3. Ejecutar scripts/build_debezium_jdbc_plugin.sh para subir el plugin a S3
#
# Uso: terraform init && terraform apply -var="deployment_name=<nombre>"

terraform {
  required_version = ">= 1.14.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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
  description = "Nombre del deployment (debe coincidir con 1-vpc, 4-kafka, 6-aurora)"
}

# ---------------------------
# Locals
# ---------------------------

locals {
  kafka_connect_version = "3.7.x"
  mcu_count             = 2
  min_worker_count      = 1
  max_worker_count      = 3
  cdc_topic             = "oracle-cdc.ADMIN.TAGS"
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

data "aws_msk_cluster" "main" {
  cluster_name = "msk-${var.deployment_name}"
}

data "aws_rds_cluster" "aurora" {
  cluster_identifier = "aurora-${var.deployment_name}"
}

# ---------------------------
# S3 Bucket para el plugin Debezium JDBC Sink
# ---------------------------

resource "aws_s3_bucket" "connector_plugins" {
  bucket        = "msk-connect-jdbc-sink-plugins-${var.deployment_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "msk-connect-jdbc-sink-plugins-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# Script para construir y subir el plugin
# ---------------------------

resource "null_resource" "build_and_upload_plugin" {
  triggers = {
    script_hash  = filemd5("${path.module}/scripts/build_debezium_jdbc_plugin.sh")
    plugins_hash = filemd5("${path.module}/scripts/plugins.txt")
  }

  provisioner "local-exec" {
    command     = "chmod +x ${path.module}/scripts/build_debezium_jdbc_plugin.sh && ${path.module}/scripts/build_debezium_jdbc_plugin.sh ${aws_s3_bucket.connector_plugins.bucket} ${data.aws_region.current.region}"
    interpreter = ["bash", "-c"]
  }

  depends_on = [aws_s3_bucket.connector_plugins]
}

# ---------------------------
# Custom Plugin: Debezium JDBC Sink + AWS MSK Config Providers + PostgreSQL driver
# ---------------------------

resource "aws_mskconnect_custom_plugin" "debezium_jdbc_sink" {
  depends_on = [null_resource.build_and_upload_plugin]

  name         = "debezium-jdbc-sink-${var.deployment_name}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.connector_plugins.arn
      file_key   = "debezium-jdbc-sink-connector/plugin-v2.zip"
    }
  }
}

# ---------------------------
# Worker Configuration con SSM Config Provider (Aurora credentials)
# ---------------------------

resource "aws_mskconnect_worker_configuration" "jdbc_sink" {
  name                    = "jdbc-sink-worker-config-${var.deployment_name}"
  description             = "Worker config con SSM Parameter Store para Debezium JDBC Sink"
  properties_file_content = <<PROPERTIES
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.json.JsonConverter
config.providers=ssm
config.providers.ssm.class=com.amazonaws.kafka.config.providers.SsmParamStoreConfigProvider
config.providers.ssm.param.region=${data.aws_region.current.region}
plugin.discovery=only_scan
PROPERTIES
}

# ---------------------------
# IAM: Service Execution Role para MSK Connect
# ---------------------------

resource "aws_iam_role" "msk_connect_service" {
  name = "msk-connect-jdbc-sink-service-${var.deployment_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "kafkaconnect.amazonaws.com"
        }
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:aws:kafkaconnect:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:connector/*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "msk_connect_service" {
  name = "msk-connect-jdbc-sink-service-policy"
  role = aws_iam_role.msk_connect_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SSM Parameter Store - Aurora credentials (creados por 6-aurora)
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/aurora/*"
      },
      # CloudWatch Logs
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/msk-connect/*"
      },
      # S3 - plugin
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.connector_plugins.arn}/*"
      },
      # MSK cluster - Connect & Describe (required for IAM auth)
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = data.aws_msk_cluster.main.arn
      },
      # MSK topics - Read (consume CDC), Write+Create (internal offsets/configs/status)
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:DescribeTopicDynamicConfiguration",
          "kafka-cluster:AlterTopic"
        ]
        Resource = "${replace(data.aws_msk_cluster.main.arn, ":cluster/", ":topic/")}/*"
      },
      # MSK consumer groups - Alter, Describe (Kafka Connect internal)
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = "${replace(data.aws_msk_cluster.main.arn, ":cluster/", ":group/")}/*"
      }
    ]
  })
}

# ---------------------------
# Security Group para MSK Connect (sink)
# ---------------------------

resource "aws_security_group" "msk_connect" {
  name        = "msk-connect-jdbc-sink-${var.deployment_name}"
  description = "Security group para workers de MSK Connect JDBC Sink"
  vpc_id      = data.aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (MSK, Aurora)"
  }

  tags = {
    Name    = "msk-connect-jdbc-sink-${var.deployment_name}"
    project = "debezium"
  }
}

# Permitir MSK Connect -> Aurora (SG creado en 6-aurora)
resource "aws_security_group_rule" "aurora_from_msk_connect" {
  type                     = "ingress"
  from_port                 = 5432
  to_port                   = 5432
  protocol                  = "tcp"
  source_security_group_id  = aws_security_group.msk_connect.id
  security_group_id         = tolist(data.aws_rds_cluster.aurora.vpc_security_group_ids)[0]
  description               = "Allow MSK Connect JDBC Sink to Aurora"
}

# ---------------------------
# MSK Connect Connector: Debezium JDBC Sink
# ---------------------------

resource "aws_mskconnect_connector" "debezium_jdbc_sink" {
  depends_on = [aws_mskconnect_custom_plugin.debezium_jdbc_sink]

  name = "debezium-jdbc-sink-aurora-${var.deployment_name}"

  kafkaconnect_version = local.kafka_connect_version

  capacity {
    autoscaling {
      mcu_count        = local.mcu_count
      min_worker_count = local.min_worker_count
      max_worker_count = local.max_worker_count
      scale_in_policy {
        cpu_utilization_percentage = 20
      }
      scale_out_policy {
        cpu_utilization_percentage = 80
      }
    }
  }

  connector_configuration = {
    "connector.class"       = "io.debezium.connector.jdbc.JdbcSinkConnector"
    "tasks.max"             = "1"
    "topics"                = local.cdc_topic
    "connection.url"         = "jdbc:postgresql://${data.aws_rds_cluster.aurora.endpoint}:${data.aws_rds_cluster.aurora.port}/${data.aws_rds_cluster.aurora.database_name}"
    "connection.username"   = "$${ssm::/aurora/user}"
    "connection.password"   = "$${ssm::/aurora/password}"
    "insert.mode"           = "upsert"
    "delete.enabled"        = "true"
    "primary.key.mode"      = "record_key"
    "schema.evolution"      = "basic"
    "use.time.zone"         = "UTC"
    "key.converter"         = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"       = "org.apache.kafka.connect.json.JsonConverter"
    "config.action.reload"  = "none"

    # SMT: Flatten Debezium envelope and add source timestamp (Oracle commit time)
    "transforms"                            = "extract,insert"
    "transforms.extract.type"               = "io.debezium.transforms.ExtractNewRecordState"
    "transforms.extract.add.fields"         = "source.ts_ms"
    "transforms.extract.add.fields.prefix"   = "_"
    "transforms.extract.delete.tombstone.handling.mode" = "rewrite"

    # SMT: Add sink write timestamp (when record is processed by connector)
    "transforms.insert.type"            = "org.apache.kafka.connect.transforms.InsertField$Value"
    "transforms.insert.timestamp.field" = "_sink_ts_ms"
  }

  kafka_cluster {
    apache_kafka_cluster {
      bootstrap_servers = data.aws_msk_cluster.main.bootstrap_brokers_sasl_iam
      vpc {
        subnets         = data.aws_subnets.private.ids
        security_groups = [aws_security_group.msk_connect.id]
      }
    }
  }

  kafka_cluster_encryption_in_transit {
    encryption_type = "TLS"
  }

  kafka_cluster_client_authentication {
    authentication_type = "IAM"
  }

  plugin {
    custom_plugin {
      arn      = aws_mskconnect_custom_plugin.debezium_jdbc_sink.arn
      revision = aws_mskconnect_custom_plugin.debezium_jdbc_sink.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connect_service.arn

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.jdbc_sink.arn
    revision = aws_mskconnect_worker_configuration.jdbc_sink.latest_revision
  }

  log_delivery {
    worker_log_delivery {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_connect.name
      }
    }
  }
}

# Log group para MSK Connect
resource "aws_cloudwatch_log_group" "msk_connect" {
  name              = "/aws/msk-connect/jdbc-sink-${var.deployment_name}"
  retention_in_days = 7

  tags = {
    Name    = "msk-connect-jdbc-sink-logs-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# Outputs
# ---------------------------

output "msk_connect_connector_arn" {
  description = "ARN del connector MSK Connect JDBC Sink"
  value       = aws_mskconnect_connector.debezium_jdbc_sink.arn
}

output "msk_connect_connector_name" {
  description = "Nombre del connector"
  value       = aws_mskconnect_connector.debezium_jdbc_sink.name
}

output "cdc_topic" {
  description = "Topic Kafka consumido"
  value       = local.cdc_topic
}

output "aurora_target" {
  description = "Aurora target (database)"
  value       = data.aws_rds_cluster.aurora.database_name
}

output "msk_connect_log_group" {
  description = "CloudWatch log group para ver errores del connector"
  value       = aws_cloudwatch_log_group.msk_connect.name
}
