# MSK Connect + Debezium Oracle CDC
#
# Requisitos previos:
# 1. Ejecutar deployment 1-vpc, 2-db, 5-kafka
# 2. En Oracle: habilitar ARCHIVELOG y supplemental logging (ver README)
# 3. Ejecutar scripts/build_debezium_oracle_plugin.sh para subir el plugin a S3
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
  description = "Nombre del deployment (debe coincidir con 1-vpc, 2-db, 5-kafka)"
}

# ---------------------------
# Locals
# ---------------------------

locals {
  kafka_connect_version = "3.7.x"
  mcu_count             = 2
  min_worker_count      = 1 # Debezium Oracle requiere tasks.max=1
  max_worker_count      = 3
  oracle_password       = "changeme123"
  debezium_topic_prefix = "oracle-cdc"
  table_include_list    = "ADMIN.TAGS"
  # Excluir RDSADMIN: tablas internas de Oracle RDS (ej. TRACEFILE_LISTING falla con AS OF SCN)
  # End of Selection
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

data "aws_db_instance" "oracle" {
  db_instance_identifier = "oracledb-source-${var.deployment_name}"
}

data "aws_msk_cluster" "main" {
  cluster_name = "msk-${var.deployment_name}"
}

# ---------------------------
# S3 Bucket para el plugin Debezium
# ---------------------------

resource "aws_s3_bucket" "connector_plugins" {
  bucket = "msk-connect-debezium-plugins-${var.deployment_name}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name    = "msk-connect-plugins-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# Script para construir y subir el plugin (ejecutar manualmente si null_resource falla)
# scripts/build_debezium_oracle_plugin.sh
# ---------------------------

resource "null_resource" "build_and_upload_plugin" {
  triggers = {
    script_hash   = filemd5("${path.module}/scripts/build_debezium_oracle_plugin.sh")
    plugins_hash  = filemd5("${path.module}/scripts/plugins.txt")
  }

  provisioner "local-exec" {
    command     = "chmod +x ${path.module}/scripts/build_debezium_oracle_plugin.sh && ${path.module}/scripts/build_debezium_oracle_plugin.sh ${aws_s3_bucket.connector_plugins.bucket} ${data.aws_region.current.region}"
    interpreter = ["bash", "-c"]
  }

  depends_on = [aws_s3_bucket.connector_plugins]
}

# ---------------------------
# Custom Plugin: Debezium Oracle + AWS MSK Config Providers (SSM, Secrets Manager, S3)
# ---------------------------

resource "aws_mskconnect_custom_plugin" "debezium_oracle" {
  depends_on = [null_resource.build_and_upload_plugin]

  name         = "debezium-oracle-${var.deployment_name}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.connector_plugins.arn
      file_key   = "debezium-oracle-connector/plugin-v2.zip"
    }
  }
}

# ---------------------------
# Data: SSM Parameters (creados por 2-db)
# ---------------------------

data "aws_ssm_parameter" "dbuser" {
  name            = "/dbtester/dbuser"
  with_decryption = true
}

data "aws_ssm_parameter" "dbpass" {
  name            = "/dbtester/dbpass"
  with_decryption = true
}

# ---------------------------
# Worker Configuration con SSM Config Provider
# ---------------------------

resource "aws_mskconnect_worker_configuration" "debezium" {
  name                    = "debezium-worker-config-${var.deployment_name}"
  description             = "Worker config con SSM Parameter Store para Debezium Oracle"
  properties_file_content = <<PROPERTIES
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.storage.StringConverter
config.providers=ssm
config.providers.ssm.class=com.amazonaws.kafka.config.providers.SsmParamStoreConfigProvider
config.providers.ssm.param.region=${data.aws_region.current.region}
PROPERTIES
}

# ---------------------------
# IAM: Service Execution Role para MSK Connect
# ---------------------------

resource "aws_iam_role" "msk_connect_service" {
  name = "msk-connect-service-${var.deployment_name}"

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
  name = "msk-connect-service-policy"
  role = aws_iam_role.msk_connect_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # SSM Parameter Store - Oracle credentials (creados por 2-db)
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:parameter/dbtester/*"
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
      # MSK topics - Read, Write, Create (schema history, CDC topics)
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:CreateTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:DescribeTopic"
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
# Security Group para MSK Connect
# ---------------------------

resource "aws_security_group" "msk_connect" {
  name        = "msk-connect-${var.deployment_name}"
  description = "Security group para workers de MSK Connect"
  vpc_id      = data.aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name    = "msk-connect-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# MSK Connect Connector: Debezium Oracle
# ---------------------------

resource "aws_mskconnect_connector" "debezium_oracle" {
  depends_on = [aws_mskconnect_custom_plugin.debezium_oracle]

  name = "debezium-oracle-cdc-${var.deployment_name}"

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
    "connector.class"                                                     = "io.debezium.connector.oracle.OracleConnector"
    "tasks.max"                                                           = "1"
    "database.hostname"                                                   = data.aws_db_instance.oracle.address
    "database.port"                                                       = tostring(data.aws_db_instance.oracle.port)
    "database.user"                                                       = "$${ssm::/dbtester/dbuser}"
    "database.password"                                                   = "$${ssm::/dbtester/dbpass}"
    "database.dbname"                                                     = data.aws_db_instance.oracle.db_name
    "topic.prefix"                                                        = local.debezium_topic_prefix
    "table.include.list"                                                  = local.table_include_list
    "database.connection.adapter"                                         = "logminer"
    "snapshot.mode"                                                       = "initial"
    "schema.history.internal.kafka.topic"                                 = "${local.debezium_topic_prefix}-schema-history"
    "schema.history.internal.kafka.bootstrap.servers"                     = data.aws_msk_cluster.main.bootstrap_brokers_sasl_iam
    "schema.history.internal.consumer.security.protocol"                  = "SASL_SSL"
    "schema.history.internal.consumer.sasl.mechanism"                     = "AWS_MSK_IAM"
    "schema.history.internal.consumer.sasl.jaas.config"                   = "software.amazon.msk.auth.iam.IAMLoginModule required;"
    "schema.history.internal.consumer.sasl.client.callback.handler.class" = "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
    "schema.history.internal.producer.security.protocol"                  = "SASL_SSL"
    "schema.history.internal.producer.sasl.mechanism"                     = "AWS_MSK_IAM"
    "schema.history.internal.producer.sasl.jaas.config"                   = "software.amazon.msk.auth.iam.IAMLoginModule required;"
    "schema.history.internal.producer.sasl.client.callback.handler.class" = "software.amazon.msk.auth.iam.IAMClientCallbackHandler"
    "include.schema.changes"                                              = "true"
    "key.converter"                                                       = "org.apache.kafka.connect.json.JsonConverter"
    "value.converter"                                                     = "org.apache.kafka.connect.json.JsonConverter"
    "key.converter.schemas.enable"                                        = "true"
    "value.converter.schemas.enable"                                      = "true"
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
      arn      = aws_mskconnect_custom_plugin.debezium_oracle.arn
      revision = aws_mskconnect_custom_plugin.debezium_oracle.latest_revision
    }
  }

  service_execution_role_arn = aws_iam_role.msk_connect_service.arn

  worker_configuration {
    arn      = aws_mskconnect_worker_configuration.debezium.arn
    revision = aws_mskconnect_worker_configuration.debezium.latest_revision
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
  name              = "/aws/msk-connect/${var.deployment_name}"
  retention_in_days = 7

  tags = {
    Name    = "msk-connect-logs-${var.deployment_name}"
    project = "debezium"
  }
}

# ---------------------------
# Outputs
# ---------------------------

output "msk_connect_connector_arn" {
  description = "ARN del connector MSK Connect"
  value       = aws_mskconnect_connector.debezium_oracle.arn
}

output "msk_connect_connector_name" {
  description = "Nombre del connector"
  value       = aws_mskconnect_connector.debezium_oracle.name
}

output "debezium_topic_prefix" {
  description = "Prefijo de los topics CDC"
  value       = local.debezium_topic_prefix
}

output "oracle_connection_info" {
  description = "Info de conexión Oracle"
  value = {
    host     = data.aws_db_instance.oracle.address
    port     = data.aws_db_instance.oracle.port
    database = data.aws_db_instance.oracle.db_name
  }
}

output "msk_connect_log_group" {
  description = "CloudWatch log group para ver errores del connector"
  value       = aws_cloudwatch_log_group.msk_connect.name
}
