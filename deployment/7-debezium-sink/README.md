# Debezium JDBC Sink - Kafka to Aurora

MSK Connect connector que consume eventos CDC del topic `oracle-cdc.ADMIN.TAGS` y los escribe en Aurora PostgreSQL.

## Requisitos previos

1. **Deployments en orden**: `1-vpc`, `2-db`, `4-kafka`, `5-debezium-cdc`, `6-aurora`
2. **Debezium Oracle connector** (5-debezium-cdc) en estado RUNNING y con el topic creado
3. **Plugin**: El script `build_debezium_jdbc_plugin.sh` se ejecuta automáticamente en `terraform apply`. Si falla, ejecutar manualmente:
   ```bash
   ./scripts/build_debezium_jdbc_plugin.sh <bucket-name> <region>
   ```

## Despliegue

```bash
cd deployment/7-debezium-sink
terraform init
terraform apply -var="deployment_name=<nombre>"
```

## Tabla destino en Aurora PostgreSQL

El connector crea la tabla `oracle_cdc_admin_tags` (topic con `.` reemplazados por `_`, lowercase en PostgreSQL) con schema evolution básica. Los eventos INSERT/UPDATE se escriben con upsert; los DELETE eliminan filas por primary key.

**Columnas de latencia CDC:** Los SMTs añaden `_source_ts_ms` (timestamp Oracle) y `_sink_ts_ms` (timestamp escritura Aurora). Usa el notebook `4 CDC Latency.ipynb` para calcular la latencia end-to-end.

## Troubleshooting: "relation already exists"

Si el connector falla con `relation "oracle-cdc_ADMIN_TAGS" already exists`, la tabla ya existe de un run anterior. Solución:

1. Conectar a Aurora PostgreSQL y ejecutar:
   ```sql
   DROP TABLE IF EXISTS "oracle-cdc_ADMIN_TAGS" CASCADE;
   DROP TABLE IF EXISTS oracle_cdc_admin_tags CASCADE;
   DROP TABLE IF EXISTS "oracle_cdc_ADMIN_TAGS" CASCADE;
   ```
2. Reiniciar el connector JDBC Sink (AWS Console > MSK > Connectors > Restart).

## Verificación

- **Estado del connector**: AWS Console > Amazon MSK > Connectors
- **Logs**: `aws logs tail /aws/msk-connect/jdbc-sink-<deployment_name> --follow`
- **Datos en Aurora**: Conectar a Aurora PostgreSQL y consultar `SELECT * FROM oracle_cdc_admin_tags LIMIT 10`

## Orden de destrucción

Si destruyes el stack, hacer en orden inverso: primero `7-debezium-sink`, luego `6-aurora`, etc.
