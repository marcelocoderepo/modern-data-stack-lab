"""
Extração das fontes públicas do caso de uso "Radar de Saúde Financeira".

Fontes:
  - CVM (dados.cvm.gov.br): demonstrações financeiras padronizadas (DFP) anuais
    das companhias abertas + cadastro de companhias.
  - Banco Central (api.bcb.gov.br): séries temporais do SGS (Selic, CDI, IPCA, dólar).

O módulo usa só a biblioteca padrão (urllib, zipfile, csv) para rodar igual
em um notebook Databricks (escrevendo em /Volumes/...) ou na sua máquina
(escrevendo em ./landing e depois subindo com `databricks fs cp`).

Layout gerado na landing zone (todos os arquivos em UTF-8):

  <dest>/cvm/cadastro/cad_cia_aberta.csv
  <dest>/cvm/dfp/<demonstracao>/ano=<AAAA>/dfp_cia_aberta_<demonstracao>_<AAAA>.csv
  <dest>/bcb/sgs/serie=<codigo>/sgs_<codigo>_<AAAA>.json   (JSON lines)

Uso local:
  python fontes.py --dest ./landing --anos 2020-2025
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import os
import time
import urllib.request
import zipfile
from datetime import date

CVM_BASE = "https://dados.cvm.gov.br/dados/CIA_ABERTA"
BCB_BASE = "https://api.bcb.gov.br/dados/serie/bcdata.sgs.{codigo}/dados"

# Demonstrações consolidadas usadas no caso (o ZIP traz ~19 arquivos; só precisamos destas).
DEMONSTRACOES = ["BPA_con", "BPP_con", "DRE_con"]

# Séries do SGS/BCB. Chave = código oficial da série.
SERIES_BCB = {
    432: ("selic_meta", "% a.a.", "diaria"),
    4389: ("cdi_anualizado", "% a.a. (base 252)", "diaria"),
    433: ("ipca_mensal", "% a.m.", "mensal"),
    13522: ("ipca_12m", "% acumulado 12 meses", "mensal"),
    1: ("dolar_ptax_venda", "R$/US$", "diaria"),
}

USER_AGENT = "databricks-finance-lab/1.0 (estudo de engenharia de dados)"


def _get(url: str, tentativas: int = 4, timeout: int = 120) -> bytes:
    """GET com retry exponencial (a API do BCB oscila e devolve 5xx/429 com frequência)."""
    ultimo_erro: Exception | None = None
    for i in range(tentativas):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as e:  # noqa: BLE001 - queremos repetir qualquer falha de rede
            ultimo_erro = e
            time.sleep(2 ** i)
    raise RuntimeError(f"Falha ao baixar {url}: {ultimo_erro}")


def _escrever(caminho: str, conteudo: bytes) -> None:
    os.makedirs(os.path.dirname(caminho), exist_ok=True)
    with open(caminho, "wb") as fh:
        fh.write(conteudo)


def _latin1_para_utf8(conteudo: bytes) -> bytes:
    # Os arquivos da CVM são ISO-8859-1. Convertendo na landing, o Auto Loader
    # lê tudo como UTF-8 (padrão) e evitamos acentos quebrados na bronze.
    return conteudo.decode("latin-1").encode("utf-8")


def extrair_cadastro_cvm(dest: str) -> str:
    """Cadastro de companhias abertas (setor, situação, mercado)."""
    url = f"{CVM_BASE}/CAD/DADOS/cad_cia_aberta.csv"
    destino = os.path.join(dest, "cvm", "cadastro", "cad_cia_aberta.csv")
    _escrever(destino, _latin1_para_utf8(_get(url)))
    return destino


def extrair_dfp_cvm(dest: str, ano: int) -> list[str]:
    """Baixa o ZIP anual da DFP e grava só as demonstrações de interesse."""
    url = f"{CVM_BASE}/DOC/DFP/DADOS/dfp_cia_aberta_{ano}.zip"
    zbytes = _get(url, timeout=600)
    gravados = []
    with zipfile.ZipFile(io.BytesIO(zbytes)) as zf:
        for dem in DEMONSTRACOES:
            nome = f"dfp_cia_aberta_{dem}_{ano}.csv"
            destino = os.path.join(dest, "cvm", "dfp", dem, f"ano={ano}", nome)
            _escrever(destino, _latin1_para_utf8(zf.read(nome)))
            gravados.append(destino)
    return gravados


def extrair_serie_bcb(dest: str, codigo: int, ano: int) -> str:
    """Uma série do SGS para um ano, gravada como JSON lines enriquecido com metadados.

    Paginar por ano evita o limite de 10 anos por consulta que o BCB aplica às
    séries diárias e deixa a carga idempotente (re-extrair um ano sobrescreve o arquivo).
    """
    nome, unidade, periodicidade = SERIES_BCB[codigo]
    fim = min(date(ano, 12, 31), date.today())
    url = (
        BCB_BASE.format(codigo=codigo)
        + f"?formato=json&dataInicial=01/01/{ano}&dataFinal={fim:%d/%m/%Y}"
    )
    registros = json.loads(_get(url))
    linhas = [
        json.dumps(
            {
                "serie_id": codigo,
                "serie_nome": nome,
                "unidade": unidade,
                "periodicidade": periodicidade,
                "data": r["data"],  # dd/MM/yyyy (formato original do BCB)
                "valor": r["valor"],  # string com ponto decimal
            },
            ensure_ascii=False,
        )
        for r in registros
    ]
    destino = os.path.join(dest, "bcb", "sgs", f"serie={codigo}", f"sgs_{codigo}_{ano}.json")
    _escrever(destino, ("\n".join(linhas) + "\n").encode("utf-8"))
    return destino


def extrair_tudo(dest: str, anos: list[int], log=print) -> dict:
    """Orquestra a extração completa. Retorna um resumo para log/auditoria."""
    resumo = {"cadastro": None, "dfp": [], "bcb": [], "erros": []}

    log("CVM cadastro…")
    resumo["cadastro"] = extrair_cadastro_cvm(dest)

    for ano in anos:
        log(f"CVM DFP {ano}…")
        try:
            resumo["dfp"] += extrair_dfp_cvm(dest, ano)
        except Exception as e:  # noqa: BLE001 - o ano corrente pode ainda não existir
            resumo["erros"].append(f"DFP {ano}: {e}")

    # Para o macro, pegamos 1 ano antes do primeiro ano da DFP (útil para médias/variações).
    for ano in range(min(anos) - 1, max(anos) + 1):
        for codigo in SERIES_BCB:
            log(f"BCB SGS {codigo} {ano}…")
            try:
                resumo["bcb"].append(extrair_serie_bcb(dest, codigo, ano))
            except Exception as e:  # noqa: BLE001
                resumo["erros"].append(f"SGS {codigo}/{ano}: {e}")
            time.sleep(0.3)  # gentileza com a API pública

    log(
        f"OK: {len(resumo['dfp'])} arquivos DFP, {len(resumo['bcb'])} arquivos SGS, "
        f"{len(resumo['erros'])} erros"
    )
    for e in resumo["erros"]:
        log(f"  ! {e}")
    return resumo


def parse_anos(texto: str) -> list[int]:
    """'2020-2025' -> [2020..2025]; '2023,2024' -> [2023, 2024]."""
    texto = texto.strip()
    if "-" in texto:
        ini, fim = (int(x) for x in texto.split("-"))
        return list(range(ini, fim + 1))
    return [int(x) for x in texto.split(",")]


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Extrai CVM + BCB para a landing zone")
    p.add_argument("--dest", default="./landing", help="pasta local ou /Volumes/<cat>/<schema>/<vol>")
    p.add_argument("--anos", default="2020-2025", help="ex.: 2020-2025 ou 2023,2024")
    args = p.parse_args()
    extrair_tudo(args.dest, parse_anos(args.anos))
