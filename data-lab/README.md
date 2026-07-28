# Data Lab — ambiente de prática local

Stack completa rodando via Docker Compose, sem custo de AWS. Substitui:
S3→MinIO, Athena/Glue+Trino/Hive→Trino+catálogo REST Iceberg, MSK→Kafka (KRaft).

## Pré-requisitos

- Docker + Docker Compose (recomendado 8 GB+ de RAM disponíveis para o Docker)
- Portas livres: 5432, 6333, 6334, 8080, 8081, 8083, 8085, 8091, 8123, 8181, 9000, 9001, 9004, 29092

## Subindo o ambiente

Não suba tudo de uma vez na primeira tentativa — suba por camadas para facilitar o diagnóstico:

```bash
# 1. Base: storage + catálogo + query engine
docker compose up -d minio mc-init postgres iceberg-rest trino

# 2. Streaming
docker compose up -d kafka schema-registry kafka-connect flink-jobmanager flink-taskmanager

# 3. Orquestração e serving
docker compose up -d airflow clickhouse qdrant

# Ver status
docker compose ps
```

## Mapa de portas

| Serviço | URL local | Usuário/senha |
|---|---|---|
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin |
| Trino UI | http://localhost:8080 | — |
| Iceberg REST catalog | http://localhost:8181 | — |
| Schema Registry | http://localhost:8081 | — |
| Kafka Connect | http://localhost:8083 | — |
| Flink UI | http://localhost:8091 | — |
| Airflow | http://localhost:8085 | admin / admin |
| ClickHouse HTTP | http://localhost:8123 | default / (vazio) |
| Qdrant | http://localhost:6333/dashboard | — |
| Postgres | localhost:5432 | postgres / postgres |
| Kafka (fora do compose) | localhost:29092 | — |

## Smoke tests

**1. Trino + Iceberg**
```bash
docker exec -it trino trino
```
```sql
CREATE SCHEMA iceberg.lab WITH (location = 's3://lakehouse/warehouse/lab');
CREATE TABLE iceberg.lab.eventos (id bigint, evento varchar, criado_em timestamp)
  WITH (partitioning = ARRAY['day(criado_em)']);
INSERT INTO iceberg.lab.eventos VALUES (1, 'teste', now());
SELECT * FROM iceberg.lab.eventos;
```

**2. Debezium (CDC do Postgres para o Kafka)**
```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d '{
    "name": "inventory-connector",
    "config": {
      "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
      "database.hostname": "postgres",
      "database.port": "5432",
      "database.user": "postgres",
      "database.password": "postgres",
      "database.dbname": "inventory",
      "topic.prefix": "inventory",
      "plugin.name": "pgoutput"
    }
  }'

# ver o tópico sendo criado
docker exec -it kafka kafka-topics --bootstrap-server kafka:9092 --list

# consumir o CDC
docker exec -it kafka kafka-console-consumer \
  --bootstrap-server kafka:9092 \
  --topic inventory.public.customers --from-beginning
```
Depois faça um `UPDATE` na tabela `customers` (via `psql`) e veja o evento chegar no consumer.

**3. Qdrant**
```bash
curl http://localhost:6333/collections
```

**4. ClickHouse**
```bash
curl "http://localhost:8123/?query=SELECT+1"
```

## dbt (roda local, não em container)

```bash
pip install dbt-trino
dbt init meu_projeto   # escolha "trino" como adapter
```
`profiles.yml`:
```yaml
meu_projeto:
  target: dev
  outputs:
    dev:
      type: trino
      host: localhost
      port: 8080
      user: dbt
      catalog: iceberg
      schema: lab
```

## Próximos passos sugeridos

1. Rodar o smoke test do Trino/Iceberg e experimentar `ALTER TABLE ... REPLACE PARTITION FIELD`
2. Subir o conector Debezium e ver o CDC fluindo no Kafka
3. Escrever um job Flink simples consumindo esse tópico
4. Criar um DAG no Airflow que dispara `dbt run` contra o Trino
5. Modelar uma tabela no ClickHouse e comparar latência de agregação com o Trino sobre Iceberg
6. Gerar embeddings de qualquer texto e indexar no Qdrant

Isso cobre, na ordem, exatamente os cinco blocos que discutimos: lakehouse → streaming → orquestração/transformação → OLAP → vector DB.
