-- Banco de origem para praticar CDC com Debezium
CREATE DATABASE inventory;

\connect inventory

CREATE TABLE customers (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    email       TEXT NOT NULL,
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO customers (name, email) VALUES
    ('Marcelo Souza', 'marcelo@example.com'),
    ('Ana Lima', 'ana@example.com'),
    ('Bruno Silva', 'bruno@example.com');

-- Necessário para o Debezium capturar o valor completo em UPDATE/DELETE
ALTER TABLE customers REPLICA IDENTITY FULL;

-- (Banco opcional para persistir o catálogo Iceberg via JDBC — ver docker-compose.yml)
CREATE DATABASE iceberg_catalog;
