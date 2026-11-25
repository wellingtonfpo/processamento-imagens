"""Gera miniaturas de fotos enviadas ao S3 e grava os metadados no DynamoDB.

Fluxo: S3 (originais) --ObjectCreated--> Lambda --> S3 (miniaturas) + DynamoDB
"""

import io
import logging
import os
from datetime import datetime, timezone
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError
from PIL import Image, ImageOps

logger = logging.getLogger()
logger.setLevel(logging.INFO)

BUCKET_MINIATURAS = os.environ["BUCKET_MINIATURAS"]
TABELA_METADADOS = os.environ["TABELA_METADADOS"]
TAMANHO_MINIATURA = int(os.environ.get("TAMANHO_MINIATURA", "256"))  # maior lado, em px
MAX_BYTES = int(os.environ.get("MAX_BYTES", str(20 * 1024 * 1024)))
MAX_PIXELS = int(os.environ.get("MAX_PIXELS", "40000000"))

# Formatos aceitos (detectados pelo conteúdo, não pela extensão do arquivo)
TIPOS_MIME = {
    "JPEG": "image/jpeg",
    "PNG": "image/png",
    "WEBP": "image/webp",
    "GIF": "image/gif",
}

# Criados fora do handler para serem reaproveitados entre invocações
s3 = boto3.client("s3")
tabela = boto3.resource("dynamodb").Table(TABELA_METADADOS)


class ImagemInvalida(Exception):
    """Erro permanente: tentar novamente não resolveria."""


def gerar_miniatura(conteudo):
    """Recebe os bytes da imagem original e devolve (bytes da miniatura, dados)."""
    try:
        with Image.open(io.BytesIO(conteudo), formats=list(TIPOS_MIME)) as original:
            formato = original.format
            largura, altura = original.size

            # Verificado antes de decodificar, para não estourar a memória
            if largura * altura > MAX_PIXELS:
                raise ImagemInvalida(f"imagem com {largura}x{altura} px excede o limite")

            # Orientações EXIF de 5 a 8 giram a foto em 90 graus
            if original.getexif().get(0x0112) in (5, 6, 7, 8):
                largura, altura = altura, largura

            imagem = original
            if imagem.mode == "P" or "transparency" in imagem.info:
                imagem = imagem.convert("RGBA")

            # Mantém a proporção e nunca amplia a imagem
            imagem.thumbnail((TAMANHO_MINIATURA, TAMANHO_MINIATURA), Image.Resampling.LANCZOS)
            miniatura = ImageOps.exif_transpose(imagem)

            opcoes = {}
            if formato == "JPEG":
                opcoes = {"quality": 85, "optimize": True}
                if miniatura.mode not in ("RGB", "L"):
                    miniatura = miniatura.convert("RGB")
                    miniatura.info.pop("icc_profile", None)

            # Remove EXIF/XMP (podem conter a localização GPS do usuário)
            for chave in ("exif", "xmp", "XML:com.adobe.xmp"):
                miniatura.info.pop(chave, None)
            if miniatura.info.get("icc_profile"):
                opcoes["icc_profile"] = miniatura.info["icc_profile"]

            saida = io.BytesIO()
            miniatura.save(saida, format=formato, **opcoes)
    except (OSError, SyntaxError, ValueError, Image.DecompressionBombError) as erro:
        # UnidentifiedImageError é subclasse de OSError
        raise ImagemInvalida(f"arquivo não é uma imagem válida: {erro}") from erro

    dados = {
        "formato": formato,
        "largura_original": largura,
        "altura_original": altura,
        "largura_miniatura": miniatura.width,
        "altura_miniatura": miniatura.height,
    }
    return saida.getvalue(), dados


def agora():
    return datetime.now(timezone.utc).isoformat()


def registrar_erro(item, motivo):
    logger.warning("Imagem rejeitada: %s (%s)", item["chave"], motivo)
    tabela.put_item(Item={**item, "status": "ERRO", "motivo_erro": motivo, "processado_em": agora()})
    return {"chave": item["chave"], "status": "ERRO"}


def processar(registro):
    bucket = registro["s3"]["bucket"]["name"]
    # Nas notificações do S3 a chave vem codificada (espaço vira "+", etc.)
    chave = unquote_plus(registro["s3"]["object"]["key"])

    # Proteção contra recursão: nunca processar o bucket de destino
    if bucket == BUCKET_MINIATURAS or chave.endswith("/"):
        logger.info("Ignorado: s3://%s/%s", bucket, chave)
        return {"chave": chave, "status": "IGNORADO"}

    try:
        objeto = s3.get_object(Bucket=bucket, Key=chave)
    except ClientError as erro:
        if erro.response["Error"]["Code"] == "NoSuchKey":
            logger.warning("Objeto removido antes do processamento: %s", chave)
            return {"chave": chave, "status": "IGNORADO"}
        raise  # erro possivelmente temporário: o Lambda tenta novamente

    item = {
        "chave": chave,
        "bucket_original": bucket,
        "tamanho_original_bytes": objeto["ContentLength"],
        "etag_original": objeto["ETag"].strip('"'),
        "enviado_em": registro.get("eventTime", agora()),
    }

    if objeto["ContentLength"] > MAX_BYTES:
        objeto["Body"].close()
        return registrar_erro(item, f"arquivo maior que {MAX_BYTES} bytes")

    conteudo = objeto["Body"].read()
    try:
        miniatura, dados = gerar_miniatura(conteudo)
    except ImagemInvalida as erro:
        return registrar_erro(item, str(erro))

    s3.put_object(
        Bucket=BUCKET_MINIATURAS,
        Key=chave,
        Body=miniatura,
        ContentType=TIPOS_MIME[dados["formato"]],
    )

    # A chave de partição é o nome do objeto: reprocessar apenas sobrescreve o item
    tabela.put_item(
        Item={
            **item,
            **dados,
            "status": "PROCESSADO",
            "bucket_miniatura": BUCKET_MINIATURAS,
            "chave_miniatura": chave,
            "tamanho_miniatura_bytes": len(miniatura),
            "processado_em": agora(),
        }
    )
    logger.info("Miniatura criada: s3://%s/%s", BUCKET_MINIATURAS, chave)
    return {"chave": chave, "status": "PROCESSADO"}


def lambda_handler(event, context):
    return {"resultados": [processar(r) for r in event.get("Records", [])]}
