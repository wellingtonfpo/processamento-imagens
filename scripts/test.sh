#!/usr/bin/env bash
# Teste ponta a ponta: envia uma foto, aguarda o processamento e confere o resultado.
# Uso: ./scripts/test.sh [caminho/da/foto]
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

FOTO="${1:-$RAIZ/exemplos/foto.jpg}"
[[ -f "$FOTO" ]] || { echo "Arquivo não encontrado: $FOTO" >&2; exit 1; }

CHAVE="testes/$(date +%Y%m%d%H%M%S)-$(basename "$FOTO")"
CHAVE_JSON="$(python3 -c 'import json,sys; print(json.dumps({"chave": {"S": sys.argv[1]}}))' "$CHAVE")"

echo "1) Enviando s3://$BUCKET_ORIGINAIS/$CHAVE"
aws s3 cp "$FOTO" "s3://$BUCKET_ORIGINAIS/$CHAVE" --only-show-errors

echo "2) Aguardando o Lambda..."
STATUS="None"
for _ in $(seq 1 30); do
  STATUS="$(aws dynamodb get-item --table-name "$TABELA" --key "$CHAVE_JSON" \
    --consistent-read --query 'Item.status.S' --output text)"
  [[ -n "$STATUS" && "$STATUS" != "None" ]] && break
  sleep 2
done

if [[ -z "$STATUS" || "$STATUS" == "None" ]]; then
  echo "Tempo esgotado. Veja os logs:" >&2
  echo "  aws logs filter-log-events --log-group-name $LOG_GROUP --region $AWS_REGION" >&2
  exit 1
fi

echo "3) Metadados no DynamoDB:"
aws dynamodb get-item --table-name "$TABELA" --key "$CHAVE_JSON" --consistent-read --output json

[[ "$STATUS" == "PROCESSADO" ]] || { echo "Processamento terminou com status $STATUS." >&2; exit 1; }

DESTINO="$RAIZ/saida/miniatura-$(basename "$CHAVE")"
mkdir -p "$RAIZ/saida"
aws s3 cp "s3://$BUCKET_MINIATURAS/$CHAVE" "$DESTINO" --only-show-errors
echo "4) Sucesso! Miniatura salva em: $DESTINO"
