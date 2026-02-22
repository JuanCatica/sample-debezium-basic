# MSK Connect + Debezium Oracle CDC

Despliega un connector MSK Connect con Debezium para capturar cambios de Oracle (CDC) y enviarlos a Kafka.

## Requisitos previos

1. **Deployments anteriores**: Ejecutar en orden: `1-vpc`, `2-db`, `4-kafka`
2. **VPC Endpoints**: El módulo `1-vpc` incluye endpoints para SSM, STS, Secrets Manager (requeridos por MSK Connect en subnets privadas sin NAT). Si ya desplegaste la VPC antes, ejecuta `terraform apply` en `1-vpc` para añadirlos.
3. **Oracle**: Habilitar ARCHIVELOG y supplemental logging (requerido por LogMiner):

```sql
-- Conectar como SYSDBA
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
```

3. **Red**: La Oracle RDS debe ser alcanzable desde las subnets privadas (el RDS en 2-db está en public subnet; MSK Connect corre en private y puede alcanzarlo por la red interna de la VPC).

## Despliegue

```bash
cd deployment/5-debezium-cdc
terraform init
terraform plan -var="deployment_name=<tu-nombre>"
terraform apply -var="deployment_name=<tu-nombre>"
```

O usando el script de deploy:

```bash
TF_VAR_deployment_name=<nombre> ./scripts/deploy 4-debezium-cdc
```

## Plugin Debezium

El `terraform apply` ejecuta automáticamente el script `scripts/build_debezium_oracle_plugin.sh` que:
- Descarga Debezium Oracle connector (2.5.0)
- Descarga AWS Secrets Manager Config Provider
- Combina ambos en un plugin ZIP
- Sube a S3

Si el script falla (ej. sin red), ejecútalo manualmente tras el primer `apply` (cuando el bucket ya exista):

```bash
# Obtén el nombre del bucket en la consola S3 o con: aws s3 ls | grep msk-connect-debezium
./scripts/build_debezium_oracle_plugin.sh <bucket-name> us-east-1
terraform apply -var="deployment_name=<nombre>"  # Re-ejecutar para crear el connector
```

## Variables

| Variable | Descripción | Default |
|----------|-------------|---------|
| deployment_name | Nombre del deployment | (requerido) |
| oracle_password | Contraseña Oracle (debe coincidir con 2-db) | changeme123 |
| debezium_topic_prefix | Prefijo para topics CDC | oracle-cdc |
| table_include_list | Tablas a capturar (regex) | .* (todas) |

## Outputs

- `msk_connect_connector_arn`: ARN del connector
- `debezium_topic_prefix`: Prefijo de topics (ej. `oracle-cdc.DBSOURCE.ADMIN.MITABLA`)
- `oracle_connection_info`: Host, port, database de Oracle

## Topics generados

Los eventos CDC se publican en temas con el formato:
`<topic.prefix>.<database>.<schema>.<table>`

Ejemplo: `oracle-cdc.DBSOURCE.ADMIN.MYTABLE`

## Troubleshooting

**"Failed to resolve Oracle database version"**
- El plugin debe incluir el Oracle JDBC driver (ojdbc8.jar). El script `build_debezium_oracle_plugin.sh` lo descarga automáticamente. Si el error persiste:
  1. Ejecutar manualmente: `./scripts/build_debezium_oracle_plugin.sh <bucket> us-east-1`
  2. `terraform destroy -target=aws_mskconnect_connector.debezium_oracle -target=aws_mskconnect_custom_plugin.debezium_oracle`
  3. `terraform apply` (recreará plugin y connector)
- RDS Oracle 19c CDB: Si tu instancia es CDB, añadir en `locals`: `oracle_pdb_name = "ORCL"` y en connector_config: `"database.pdb.name" = local.oracle_pdb_name`
- Verificar conectividad: MSK Connect debe poder alcanzar Oracle en puerto 1521 (se añade regla de SG automáticamente)
