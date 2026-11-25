"""Testes locais com AWS simulada (moto). Não acessam a nuvem.

    pip install -r requirements.txt -r requirements-dev.txt
    python -m pytest tests -q
"""

import importlib
import io
import sys
from pathlib import Path
from urllib.parse import quote_plus

import boto3
import pytest
from moto import mock_aws
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

ORIGEM, DESTINO, TABELA = "originais-teste", "miniaturas-teste", "metadados-teste"


@pytest.fixture
def app(monkeypatch):
    for nome, valor in {
        "AWS_DEFAULT_REGION": "us-east-1",
        "AWS_ACCESS_KEY_ID": "teste",
        "AWS_SECRET_ACCESS_KEY": "teste",
        "BUCKET_MINIATURAS": DESTINO,
        "TABELA_METADADOS": TABELA,
    }.items():
        monkeypatch.setenv(nome, valor)
    with mock_aws():
        s3 = boto3.client("s3")
        s3.create_bucket(Bucket=ORIGEM)
        s3.create_bucket(Bucket=DESTINO)
        boto3.client("dynamodb").create_table(
            TableName=TABELA,
            AttributeDefinitions=[{"AttributeName": "chave", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "chave", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        sys.modules.pop("lambda_function", None)
        yield importlib.import_module("lambda_function")


def imagem(formato="JPEG", modo="RGB", tamanho=(1200, 800), **opcoes):
    saida = io.BytesIO()
    Image.new(modo, tamanho).save(saida, format=formato, **opcoes)
    return saida.getvalue()


def evento(chave, bucket=ORIGEM):
    return {
        "Records": [
            {
                "eventTime": "2026-01-01T12:00:00.000Z",
                "s3": {"bucket": {"name": bucket}, "object": {"key": quote_plus(chave, safe="/")}},
            }
        ]
    }


def executar(app, chave, conteudo):
    app.s3.put_object(Bucket=ORIGEM, Key=chave, Body=conteudo)
    status = app.lambda_handler(evento(chave), None)["resultados"][0]["status"]
    return status, app.tabela.get_item(Key={"chave": chave}).get("Item")


def miniatura(app, chave):
    objeto = app.s3.get_object(Bucket=DESTINO, Key=chave)
    return Image.open(io.BytesIO(objeto["Body"].read())), objeto["ContentType"]


@pytest.mark.parametrize(
    "formato,modo",
    [("JPEG", "RGB"), ("JPEG", "L"), ("JPEG", "CMYK"), ("PNG", "RGBA"), ("PNG", "P"),
     ("PNG", "1"), ("PNG", "LA"), ("WEBP", "RGBA"), ("GIF", "P")],
)
def test_formatos(app, formato, modo):
    status, item = executar(app, "foto", imagem(formato, modo))
    img, tipo = miniatura(app, "foto")
    assert status == "PROCESSADO"
    assert img.format == formato and tipo == f"image/{formato.lower()}"
    assert max(img.size) == 256
    assert (item["largura_original"], item["altura_original"]) == (1200, 800)
    assert (item["largura_miniatura"], item["altura_miniatura"]) == img.size


def test_nome_com_espaco_e_acento(app):
    status, item = executar(app, "álbum/minha foto (1)+a.jpg", imagem())
    assert status == "PROCESSADO"
    assert item["chave_miniatura"] == "álbum/minha foto (1)+a.jpg"


def test_orientacao_exif_aplicada_e_metadados_removidos(app):
    exif = Image.Exif()
    exif[0x0112] = 6  # girar 90 graus
    exif[0x010F] = "Camera"
    for formato in ("JPEG", "PNG", "WEBP"):
        _, item = executar(app, formato, imagem(formato, exif=exif.tobytes()))
        img, _ = miniatura(app, formato)
        assert img.height == 256 and img.width < img.height
        assert (item["largura_original"], item["altura_original"]) == (800, 1200)
        assert not dict(img.getexif())


def test_nao_amplia_imagem_pequena(app):
    executar(app, "p.png", imagem("PNG", tamanho=(40, 30)))
    assert miniatura(app, "p.png")[0].size == (40, 30)


@pytest.mark.parametrize("conteudo", [b"nao sou imagem", b"", imagem()[:300], imagem("BMP")])
def test_arquivo_invalido(app, conteudo):
    status, item = executar(app, "ruim.jpg", conteudo)
    assert status == "ERRO" and item["status"] == "ERRO" and item["motivo_erro"]
    assert app.s3.list_objects_v2(Bucket=DESTINO)["KeyCount"] == 0


@pytest.mark.parametrize("limite", ["MAX_BYTES", "MAX_PIXELS"])
def test_limites(app, monkeypatch, limite):
    monkeypatch.setattr(app, limite, 100)
    assert executar(app, "grande.jpg", imagem())[0] == "ERRO"


def test_objeto_inexistente_e_ignorado(app):
    assert app.lambda_handler(evento("sumiu.jpg"), None)["resultados"][0]["status"] == "IGNORADO"


def test_protecao_contra_recursao(app):
    resultado = app.lambda_handler(evento("x.jpg", bucket=DESTINO), None)
    assert resultado["resultados"][0]["status"] == "IGNORADO"


def test_erro_de_infraestrutura_propaga_para_nova_tentativa(app, monkeypatch):
    monkeypatch.setattr(app, "BUCKET_MINIATURAS", "bucket-que-nao-existe")
    with pytest.raises(app.ClientError):
        executar(app, "foto.jpg", imagem())
