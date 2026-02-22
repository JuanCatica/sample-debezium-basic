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
CONFIG_PROVIDER_VERSION="0.4.0"
ORACLE_JDBC_VERSION="21.18.0.0"
PLUGIN_S3_KEY="debezium-oracle-connector/plugin-v2.zip"

DEBEZIUM_URL="https://repo1.maven.org/maven2/io/debezium/debezium-connector-oracle/${DEBEZIUM_VERSION}/debezium-connector-oracle-${DEBEZIUM_VERSION}-plugin.tar.gz"
# AWS official config provider (Secrets Manager, SSM, S3) - jcustenborder releases have no assets
CONFIG_PROVIDER_URL="https://github.com/aws-samples/msk-config-providers/releases/download/r${CONFIG_PROVIDER_VERSION}/msk-config-providers-${CONFIG_PROVIDER_VERSION}-with-dependencies.zip"
# Oracle JDBC driver - Debezium Oracle connector does NOT include it (licensing)
ORACLE_JDBC_URL="https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc8/${ORACLE_JDBC_VERSION}/ojdbc8-${ORACLE_JDBC_VERSION}.jar"
ORACLE_ORAI18N_URL="https://repo1.maven.org/maven2/com/oracle/database/nls/orai18n/${ORACLE_JDBC_VERSION}/orai18n-${ORACLE_JDBC_VERSION}.jar"

BUCKET="${1:?Usage: $0 <s3-bucket> <aws-region>}"
AWS_REGION="${2:?Usage: $0 <s3-bucket> <aws-region>}"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

echo "==> Descargando Debezium Oracle connector ${DEBEZIUM_VERSION}..."
curl -sSL -o "$WORK_DIR/debezium.tar.gz" "$DEBEZIUM_URL"

echo "==> Descargando AWS MSK Config Providers ${CONFIG_PROVIDER_VERSION}..."
curl -sSL -L -o "$WORK_DIR/config-provider.zip" "$CONFIG_PROVIDER_URL"

echo "==> Descargando Oracle JDBC driver ${ORACLE_JDBC_VERSION}..."
curl -sSL -o "$WORK_DIR/ojdbc8.jar" "$ORACLE_JDBC_URL"
curl -sSL -o "$WORK_DIR/orai18n.jar" "$ORACLE_ORAI18N_URL"

echo "==> Extrayendo archivos..."
mkdir -p "$WORK_DIR/debezium" "$WORK_DIR/config-provider"
tar -xzf "$WORK_DIR/debezium.tar.gz" -C "$WORK_DIR/debezium"
unzip -q -o "$WORK_DIR/config-provider.zip" -d "$WORK_DIR/config-provider"

echo "==> Combinando plugins..."
PLUGIN_DIR="$WORK_DIR/plugin"
mkdir -p "$PLUGIN_DIR/lib"

# Copiar todos los JARs a lib/
find "$WORK_DIR/debezium" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;
find "$WORK_DIR/config-provider" -name "*.jar" -exec cp {} "$PLUGIN_DIR/lib/" \;
cp "$WORK_DIR/ojdbc8.jar" "$WORK_DIR/orai18n.jar" "$PLUGIN_DIR/lib/"

# Copiar directorios adicionales si existen (doc, etc.)
for dir in doc etc; do
  if [ -d "$WORK_DIR/debezium/$dir" ]; then
    cp -r "$WORK_DIR/debezium/$dir" "$PLUGIN_DIR/" 2>/dev/null || true
  fi
done

echo "==> Creando plugin.zip..."
(cd "$PLUGIN_DIR" && zip -rq "$WORK_DIR/plugin.zip" .)

echo "==> Subiendo a s3://${BUCKET}/${PLUGIN_S3_KEY}..."
aws s3 cp "$WORK_DIR/plugin.zip" "s3://${BUCKET}/${PLUGIN_S3_KEY}" --region "$AWS_REGION"

echo "==> Plugin listo en s3://${BUCKET}/${PLUGIN_S3_KEY}"
