# Modern Data Stack Lab

Ambiente local de prática para engenharia de dados moderna: lakehouse, streaming/CDC, orquestração, OLAP, banco vetorial e transformação com dbt — tudo via Docker Compose, sem custo de nuvem. Serve como laboratório pessoal para testar conceitos que normalmente exigiriam serviços gerenciados (S3, Glue/Athena, MSK, Redshift).

## Arquitetura

```
                 ┌─────────────┐        ┌──────────────┐
  Postgres ──────▶  Debezium   │──────▶ │    Kafka     │
 (OLTP fonte)     │  (CDC)     │        │  (KRaft)     │
                 └─────────────┘        └──────┬───────┘
                                                │
                                         ┌──────▼───────┐
                                         │    Flink     │
                                         │ (streaming)  │
                                         └──────┬───────┘
                                                │
        ┌───────────────────────────────────────▼──────────────────┐
        │                    MinIO (S3) + Iceberg REST catalog       │
        └───────────────────────────┬─────────────────┬─────────────┘
                                     │                 │
                              ┌──────▼─────┐    ┌──────▼──────┐
                              │   Trino    │    │     dbt     │
                              │  (query)   │◀───┤ (transform) │
                              └──────┬─────┘    └─────────────┘
                                     │
                    ┌────────────────┼────────────────┐
              ┌──────▼─────┐  ┌──────▼─────┐   ┌───────▼──────┐
              │ ClickHouse │  │   Pinot    │   │   Qdrant     │
              │   (OLAP)   │  │ (realtime) │   │ (vetorial)   │
              └──────┬─────┘  └──────┬─────┘   └──────────────┘
                     └───────┬───────┘
                       ┌─────▼─────┐
                       │  Grafana  │
                       │ (viz)     │
                       └───────────┘

  Airflow orquestra o pipeline inteiro (não representado nas setas acima).
```

## Ferramentas e por que cada uma está aqui

| Camada | Ferramenta | Substitui (nuvem) | Papel no lab |
|---|---|---|---|
| Storage | MinIO | Amazon S3 | Object storage compatível com S3 para o data lake |
| Catálogo | Iceberg REST catalog | AWS Glue Data Catalog | Metadados de tabelas Iceberg (schema, partições, snapshots) |
| Query engine | Trino | Athena | SQL federado sobre Iceberg (e também sobre o Postgres) |
| Banco fonte | Postgres | RDS | Sistema transacional de origem para praticar CDC |
| CDC | Debezium (Kafka Connect) | DMS | Captura mudanças do Postgres e publica no Kafka |
| Streaming | Kafka (modo KRaft, sem Zookeeper) | MSK | Broker de mensageria para os eventos de CDC |
| Schema | Schema Registry | Glue Schema Registry | Compatibilidade de schema Avro/JSON entre produtores/consumidores |
| Processamento | Flink | Kinesis Data Analytics | Consome Kafka e escreve nas tabelas Iceberg em streaming |
| Orquestração | Airflow (standalone) | MWAA | Agenda e monitora os pipelines (DAGs) |
| Transformação | dbt (adapter Trino) | dbt Cloud | Modelagem SQL versionada sobre o lakehouse |
| OLAP batch | ClickHouse | Redshift | Análises agregadas de alta performance |
| OLAP realtime | Apache Pinot + Zookeeper | Kinesis Analytics / Redshift Streaming | Consultas em tempo real sobre dados de streaming |
| Vetorial | Qdrant | OpenSearch (k-NN) / Bedrock KB | Busca por similaridade / embeddings |
| Visualização | Grafana | QuickSight | Dashboards sobre ClickHouse/Postgres |

## Pré-requisitos

- Docker Desktop com **8 GB+ de RAM alocada** (Settings → Resources → Advanced). Com menos que isso, serviços como o Airflow podem travar por falta de memória.
- Portas livres: `2181 5432 6333 6334 8080 8081 8083 8085 8091 8099 8123 8181 9000 9001 9002 9004 29092 3000`
- Python 3.9+ e `pip` (para o dbt, que roda fora do Docker)

## Instalação passo a passo

**1. Clonar o repositório**
```bash
git clone https://github.com/marcelocoderepo/modern-data-stack-lab.git
cd modern-data-stack-lab/data-lab
```

**2. Configurar variáveis de ambiente**
```bash
cp .env.example .env
# ajuste as senhas se quiser; os defaults já funcionam para uso local
```

**3. Subir o ambiente em camadas** (evita competir por recursos na primeira subida)
```bash
# Lakehouse: storage + catálogo + query engine
docker compose up -d minio mc-init postgres iceberg-rest trino

# Streaming
docker compose up -d kafka schema-registry kafka-connect flink-jobmanager flink-taskmanager

# Orquestração, OLAP e vetorial
docker compose up -d airflow clickhouse qdrant grafana zookeeper pinot-controller pinot-broker pinot-server

docker compose ps
```

**4. Baixar os JARs do Flink** (não versionados no repo — 133 MB de binários)
```bash
mkdir -p flink/lib && cd flink/lib
curl -L -o flink-sql-connector-kafka-3.3.0-1.19.jar \
  https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/3.3.0-1.19/flink-sql-connector-kafka-3.3.0-1.19.jar
curl -L -o iceberg-flink-runtime-1.19-1.9.2.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.19/1.9.2/iceberg-flink-runtime-1.19-1.9.2.jar
curl -L -o flink-s3-fs-hadoop-1.19.3.jar \
  https://repo1.maven.org/maven2/org/apache/flink/flink-s3-fs-hadoop/1.19.3/flink-s3-fs-hadoop-1.19.3.jar
curl -L -o hadoop-hdfs-client-3.3.4.jar \
  https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-hdfs-client/3.3.4/hadoop-hdfs-client-3.3.4.jar
curl -L -o iceberg-aws-bundle-1.9.2.jar \
  https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.9.2/iceberg-aws-bundle-1.9.2.jar
cd ../..
docker compose up -d flink-jobmanager flink-taskmanager  # recarrega com os JARs
```

**5. Configurar o dbt** (fora do Docker)
```bash
python3 -m venv dbt-venv && source dbt-venv/bin/activate
pip install dbt-trino
```
`~/.dbt/profiles.yml`:
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

## Utilização

**Mapa de portas**

| Serviço | URL | Usuário/senha |
|---|---|---|
| MinIO Console | http://localhost:9001 | minioadmin / minioadmin |
| Trino UI | http://localhost:8080 | — |
| Airflow | http://localhost:8085 | admin / admin |
| Flink UI | http://localhost:8091 | — |
| ClickHouse HTTP | http://localhost:8123 | default / (vazio) |
| Qdrant Dashboard | http://localhost:6333/dashboard | — |
| Grafana | http://localhost:3000 | admin / admin |
| Pinot Controller | http://localhost:9002 | — |

**Smoke test — Trino + Iceberg**
```bash
docker exec -it trino trino --execute "
CREATE SCHEMA IF NOT EXISTS iceberg.lab WITH (location = 's3://lakehouse/warehouse/lab');
CREATE TABLE IF NOT EXISTS iceberg.lab.eventos (id bigint, evento varchar, criado_em timestamp)
  WITH (partitioning = ARRAY['day(criado_em)']);
INSERT INTO iceberg.lab.eventos VALUES (1, 'teste', now());
SELECT * FROM iceberg.lab.eventos;
"
```

**Smoke test — CDC (Debezium)**
```bash
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d '{
  "name": "inventory-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres", "database.port": "5432",
    "database.user": "postgres", "database.password": "postgres",
    "database.dbname": "inventory", "topic.prefix": "inventory",
    "plugin.name": "pgoutput"
  }
}'
docker exec -it kafka kafka-console-consumer --bootstrap-server kafka:9092 \
  --topic inventory.public.customers --from-beginning
```
Depois faça um `UPDATE` na tabela `customers` via `psql` e veja o evento chegar no consumer.

**dbt**
```bash
cd meu_projeto
dbt run
dbt test
```

**Airflow**: acesse http://localhost:8085, ative a DAG `lab_smoke_test` e dispare manualmente para validar a orquestração.

## Segurança

Todas as credenciais deste repositório são **defaults de desenvolvimento local**, definidas em `data-lab/.env` (não versionado — veja `.env.example`). Não reutilize estes valores fora de ambiente local. O catálogo `trino/catalog/postgresql.properties` também usa essas mesmas credenciais locais fixas (limitação do Trino, que não lê `.env` diretamente).

## Estrutura do repositório

```
data-lab/       stack Docker Compose (lakehouse, streaming, orquestração, OLAP, vetorial)
meu_projeto/    projeto dbt (modelos, testes, seeds)
databricks-finance-lab/  caso de uso Databricks: indicadores financeiros CVM + BCB (SDP medalhão, Dashboard AI/BI, Genie)
```

## Autor

Marcelo Santos ([@marcelocoderepo](https://github.com/marcelocoderepo))
