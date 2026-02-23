#!/usr/bin/env bash
# Construye el plugin Debezium JDBC Sink + AWS MSK Config Providers + PostgreSQL driver
# y lo sube a S3.
#
# Uso: ./build_debezium_jdbc_plugin.sh <bucket-name> <aws-region>
# Ejemplo: ./build_debezium_jdbc_plugin.sh msk-connect-jdbc-sink-plugins-mydeploy-123456789 us-east-1
#
# Requisitos: curl, tar, unzip, zip, aws cli

set -euo pipefail

DEBEZIUM_JDBC_VERSION="2.5.0.Final"
CONFIG_PROVIDER_VERSION="0.4.0"
POSTGRESQL_DRIVER_VERSION="42.7.2"
PLUGIN_S3_KEY="debezium-jdbc-sink-connector/plugin-v2.zip"

DEBEZIUM_JDBC_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-jdbc/${DEBEZIUM_JDBC_VERSION}/debezium-connector-jdbc-${DEBEZIUM_JDBC_VERSION}-plugin.tar.gz"
CONFIG_PROVIDER_URL="https://github.com/aws-samples/msk-config-providers/releases/download/r${CONFIG_PROVIDER_VERSION}/msk-config-providers-${CONFIG_PROVIDER_VERSION}-with-dependencies.zip"
POSTGRESQL_DRIVER_URL="https://repo1.maven.org/maven2/org/postgresql/postgresql/${POSTGRESQL_DRIVER_VERSION}/postgresql-${POSTGRESQL_DRIVER_VERSION}.jar"

BUCKET="${1:?Usage: $0 <s3-bucket> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <s3-bucket> <aws-region>}"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "==> Descargando Debezium JDBC Sink connector ${DEBEZIUM_JDBC_VERSION}..."
curl -sSL -o "$WORK_DIR/debezium-jdbc.tar.gz" "$DEBEZIUM_JDBC_URL"

echo "==> Descargando AWS MSK Config Providers ${CONFIG_PROVIDER_VERSION}..."
curl -sSL -L -o "$WORK_DIR/config-provider.zip" "$CONFIG_PROVIDER_URL"

echo "==> Descargando PostgreSQL JDBC driver ${POSTGRESQL_DRIVER_VERSION}..."
curl -sSL -o "$WORK_DIR/postgresql-connector.jar" "$POSTGRESQL_DRIVER_URL"

echo "==> Extrayendo archivos..."
mkdir -p "$WORK_DIR/debezium-jdbc" "$WORK_DIR/config-provider"
tar -xzf "$WORK_DIR/debezium-jdbc.tar.gz" -C "$WORK_DIR/debezium-jdbc"
unzip -q -o "$WORK_DIR/config-provider.zip" -d "$WORK_DIR/config-provider"

echo "==> Combinando plugins..."
PLUGIN_DIR="$WORK_DIR/plugin"
mkdir -p "$PLUGIN_DIR/lib"

find "$WORK_DIR/debezium-jdbc" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;
find "$WORK_DIR/config-provider" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;
cp "$WORK_DIR/postgresql-connector.jar" "$PLUGIN_DIR/lib/"

for dir in doc etc; do
  if [ -d "$WORK_DIR/debezium-jdbc/$dir" ]; then
    cp -r "$WORK_DIR/debezium-jdbc/$dir" "$PLUGIN_DIR/" 2>/dev/null || true
  fi
done

echo "==> Creando plugin.zip..."
(cd "$PLUGIN_DIR" && zip -rq "$WORK_DIR/plugin.zip" .)

echo "==> Subiendo a s3://${BUCKET}/${PLUGIN_S3_KEY}..."
aws s3 cp "$WORK_DIR/plugin.zip" "s3://${BUCKET}/${PLUGIN_S3_KEY}" --region "$AWS_REGION"

echo "==> Plugin listo en s3://${BUCKET}/${PLUGIN_S3_KEY}"
