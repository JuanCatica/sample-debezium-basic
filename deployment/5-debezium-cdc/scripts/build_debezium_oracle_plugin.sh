#!/usr/bin/env bash
# Construye el plugin Debezium Oracle + AWS Secrets Manager Config Provider
# y lo sube a S3.
#
# Uso: ./build_debezium_oracle_plugin.sh <bucket-name> <aws-region>
# Ejemplo: ./build_debezium_oracle_plugin.sh msk-connect-debezium-plugins-mydeploy-123456789 us-east-1
#
# Requisitos: curl, tar, unzip, zip, aws cli

set -euo pipefail

DEBEZIUM_VERSION="2.5.0.Final"
CONFIG_PROVIDER_VERSION="0.1.2"

DEBEZIUM_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/${DEBEZIUM_VERSION}/debezium-connector-oracle-${DEBEZIUM_VERSION}-plugin.tar.gz"
CONFIG_PROVIDER_URL="https://github.com/jcustenborder/kafka-config-provider-aws/releases/download/${CONFIG_PROVIDER_VERSION}/jcustenborder-kafka-config-provider-aws-${CONFIG_PROVIDER_VERSION}.zip"

BUCKET="${1:?Usage: $0 <s3-bucket> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <s3-bucket> <aws-region>}"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "==> Descargando Debezium Oracle connector ${DEBEZIUM_VERSION}..."
curl -sSL -o "$WORK_DIR/debezium.tar.gz" "$DEBEZIUM_URL"

echo "==> Descargando AWS Secrets Manager Config Provider ${CONFIG_PROVIDER_VERSION}..."
curl -sSL -L -o "$WORK_DIR/config-provider.zip" "$CONFIG_PROVIDER_URL"

echo "==> Extrayendo archivos..."
mkdir -p "$WORK_DIR/debezium" "$WORK_DIR/config-provider"
tar -xzf "$WORK_DIR/debezium.tar.gz" -C "$WORK_DIR/debezium"
unzip -q "$WORK_DIR/config-provider.zip" -d "$WORK_DIR/config-provider"

echo "==> Combinando plugins..."
PLUGIN_DIR="$WORK_DIR/plugin"
mkdir -p "$PLUGIN_DIR/lib"

# Copiar todos los JARs a lib/
find "$WORK_DIR/debezium" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;
find "$WORK_DIR/config-provider" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;

# Copiar directorios adicionales si existen (doc, etc.)
for dir in doc etc; do
  if [ -d "$WORK_DIR/debezium/$dir" ]; then
    cp -r "$WORK_DIR/debezium/$dir" "$PLUGIN_DIR/" 2>/dev/null || true
  fi
done

echo "==> Creando plugin.zip..."
(cd "$PLUGIN_DIR" && zip -rq "$WORK_DIR/plugin.zip" .)

echo "==> Subiendo a s3://${BUCKET}/debezium-oracle-connector/plugin.zip..."
aws s3 cp "$WORK_DIR/plugin.zip" "s3://${BUCKET}/debezium-oracle-connector/plugin.zip" --region "$AWS_REGION"

echo "==> Plugin listo en s3://${BUCKET}/debezium-oracle-connector/plugin.zip"
