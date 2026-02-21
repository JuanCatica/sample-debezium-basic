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

variable "oracle_password" {
  type        = string
  description = "Contraseña del usuario Oracle (debe coincidir con 2-db)"
  default     = "changeme123"
  sensitive   = true
}

variable "debezium_topic_prefix" {
  type        = string
  description = "Prefijo para los topics de Debezium"
  default     = "oracle-cdc"
}

variable "table_include_list" {
  type        = string
  description = "Lista de tablas/schemas a capturar (ej: ADMIN.table1, ADMIN.table2 o .* para todo)"
  default     = ".*"
}

# ---------------------------
# Locals
# ---------------------------

locals {
  kafka_connect_version = "3.6.0"
  mcu_count             = 2
  worker_count          = 1 # Debezium Oracle requiere tasks.max=1
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
    script_hash = filemd5("${path.module}/scripts/build_debezium_oracle_plugin.sh")
  }

  provisioner "local-exec" {
    command     = "chmod +x ${path.module}/scripts/build_debezium_oracle_plugin.sh && ${path.module}/scripts/build_debezium_oracle_plugin.sh ${aws_s3_bucket.connector_plugins.bucket} ${data.aws_region.current.region}"
    interpreter = ["bash", "-c"]
  }

  depends_on = [aws_s3_bucket.connector_plugins]
}

# ---------------------------
# Custom Plugin: Debezium Oracle + AWS Secrets Manager Config Provider
# ---------------------------

resource "aws_mskconnect_custom_plugin" "debezium_oracle" {
  depends_on = [null_resource.build_and_upload_plugin]

  name         = "debezium-oracle-${var.deployment_name}"
  content_type = "ZIP"

  location {
    s3 {
      bucket_arn = aws_s3_bucket.connector_plugins.arn
      file_key   = "debezium-oracle-connector/plugin.zip"
    }
  }
}

# ---------------------------
# Secrets Manager: credenciales Oracle
# ---------------------------

resource "aws_secretsmanager_secret" "oracle_credentials" {
  name        = "debezium/oracle-${var.deployment_name}"
  description = "Credenciales Oracle para Debezium CDC"

  tags = {
    Name    = "oracle-creds-${var.deployment_name}"
    project = "debezium"
  }
}

resource "aws_secretsmanager_secret_version" "oracle_credentials" {
  secret_id = aws_secretsmanager_secret.oracle_credentials.id

  secret_string = jsonencode({
    username = data.aws_db_instance.oracle.master_username
    password = var.oracle_password
  })
}

# ---------------------------
# Worker Configuration con Secrets Manager Config Provider
# ---------------------------

resource "aws_mskconnect_worker_configuration" "debezium" {
  name                    = "debezium-worker-config-${var.deployment_name}"
  description             = "Worker config con Secrets Manager para Debezium Oracle"
  properties_file_content = <<PROPERTIES
key.converter=org.apache.kafka.connect.storage.StringConverter
value.converter=org.apache.kafka.connect.storage.StringConverter
config.providers=secretManager
config.providers.secretManager.class=com.github.jcustenborder.kafka.config.aws.SecretsManagerConfigProvider
config.providers.secretManager.param.aws.region=${data.aws_region.current.region}
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
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.oracle_credentials.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/msk-connect/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.connector_plugins.arn}/*"
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

# Permitir que MSK Connect se conecte a Oracle (añadir al SG de RDS vía data)
# Nota: El SG de RDS en 2-db permite 0.0.0.0/0 en 1521, así que no hace falta modificar

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
      min_worker_count = local.worker_count
      max_worker_count = local.worker_count
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
    "database.user"                                                       = "$${secretManager:${aws_secretsmanager_secret.oracle_credentials.name}:username}"
    "database.password"                                                   = "$${secretManager:${aws_secretsmanager_secret.oracle_credentials.name}:password}"
    "database.dbname"                                                     = data.aws_db_instance.oracle.db_name
    "topic.prefix"                                                        = var.debezium_topic_prefix
    "table.include.list"                                                  = var.table_include_list
    "database.connection.adapter"                                         = "logminer"
    "snapshot.mode"                                                       = "initial"
    "schema.history.internal.kafka.topic"                                 = "${var.debezium_topic_prefix}-schema-history"
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
  value       = var.debezium_topic_prefix
}

output "oracle_connection_info" {
  description = "Info de conexión Oracle"
  value = {
    host     = data.aws_db_instance.oracle.address
    port     = data.aws_db_instance.oracle.port
    database = data.aws_db_instance.oracle.db_name
  }
}
