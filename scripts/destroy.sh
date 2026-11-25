#!/usr/bin/env bash
# Remove TODOS os recursos, inclusive fotos, miniaturas e metadados.
# Uso: ./scripts/destroy.sh [--sim]   (--sim pula a confirmação)
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

cat <<FIM
Serão apagados permanentemente (conta $ACCOUNT_ID, região $AWS_REGION):
  s3://$BUCKET_ORIGINAIS (e todo o conteúdo)
  s3://$BUCKET_MINIATURAS (e todo o conteúdo)
  Tabela DynamoDB $TABELA
  Função Lambda $FUNCAO
  Role IAM $ROLE
  Log group $LOG_GROUP
FIM

if [[ "${1:-}" != "--sim" ]]; then
  read -r -p "Digite o nome do projeto ($PROJETO) para confirmar: " resposta
  [[ "$resposta" == "$PROJETO" ]] || { echo "Cancelado."; exit 1; }
fi

if aws lambda get-function --function-name "$FUNCAO" >/dev/null 2>&1; then
  aws lambda delete-function --function-name "$FUNCAO" >/dev/null
  echo "Removida a função $FUNCAO"
fi

for bucket in "$BUCKET_ORIGINAIS" "$BUCKET_MINIATURAS"; do
  if aws s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    aws s3 rm "s3://$bucket" --recursive --only-show-errors
    aws s3api delete-bucket --bucket "$bucket"
    echo "Removido o bucket $bucket"
  fi
done

if aws dynamodb describe-table --table-name "$TABELA" >/dev/null 2>&1; then
  aws dynamodb delete-table --table-name "$TABELA" >/dev/null
  aws dynamodb wait table-not-exists --table-name "$TABELA"
  echo "Removida a tabela $TABELA"
fi

if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLITICA" >/dev/null 2>&1 || true
  aws iam delete-role --role-name "$ROLE"
  echo "Removida a role $ROLE"
fi

if aws logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1; then
  echo "Removido o log group $LOG_GROUP"
fi

echo "Limpeza concluída."
