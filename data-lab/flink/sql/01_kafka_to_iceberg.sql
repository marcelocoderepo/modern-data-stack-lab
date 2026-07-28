CREATE CATALOG iceberg WITH (
  'type' = 'iceberg',
  'catalog-type' = 'rest',
  'uri' = 'http://iceberg-rest:8181',
  'warehouse' = 's3://lakehouse/warehouse',
  's3.endpoint' = 'http://minio:9000',
  's3.path-style-access' = 'true',
  's3.access-key-id' = 'minioadmin',
  's3.secret-access-key' = 'minioadmin'
);

USE CATALOG iceberg;

CREATE TABLE kafka_customers (
  id INT,
  name STRING,
  email STRING,
  created_at TIMESTAMP(3)
) WITH (
  'connector' = 'kafka',
  'topic' = 'inventory.public.customers',
  'properties.bootstrap.servers' = 'kafka:9092',
  'properties.group.id' = 'flink-iceberg-sink',
  'scan.startup.mode' = 'earliest-offset',
  'format' = 'debezium-json'
);
