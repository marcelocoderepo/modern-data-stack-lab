from datetime import datetime

from airflow import DAG
from airflow.operators.python import PythonOperator


def hello():
    print("Ambiente de prática funcionando! Agora conecte isto ao Trino/dbt.")


with DAG(
    dag_id="lab_smoke_test",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    tags=["lab"],
) as dag:
    PythonOperator(task_id="hello", python_callable=hello)
