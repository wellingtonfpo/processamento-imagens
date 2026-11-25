#!/usr/bin/env bash
# Cria (ou atualiza) toda a infraestrutura e publica o código. Pode ser reexecutado.
set -euo pipefail
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

passo() { printf '\n==> %s\n' "$*"; }

echo "Conta: $ACCOUNT_ID | Região: $AWS_REGION | Projeto: $PROJETO"

passo "1/7 Empacotando a função"
RUNTIME="$RUNTIME" ARQUITETURA="$ARQUITETURA" bash "$RAIZ/scripts/build.sh"
ZIP="fileb://build/funcao.zip"   # caminho relativo à raiz do projeto
cd "$RAIZ"

passo "2/7 Buckets S3"
criar_bucket() {
  local bucket="$1"
  if aws s3api head-bucket --bucket "$bucket" --expected-bucket-owner "$ACCOUNT_ID" >/dev/null 2>&1; then
    echo "Já existe: $bucket"
  else
    # Em us-east-1 a API não aceita LocationConstraint
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$bucket" >/dev/null
    else
      aws s3api create-bucket --bucket "$bucket" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
    fi
    aws s3api wait bucket-exists --bucket "$bucket"
    echo "Criado: $bucket"
  fi
  aws s3api put-public-access-block --bucket "$bucket" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
}
criar_bucket "$BUCKET_ORIGINAIS"
criar_bucket "$BUCKET_MINIATURAS"

passo "3/7 Tabela DynamoDB"
if aws dynamodb describe-table --table-name "$TABELA" >/dev/null 2>&1; then
  echo "Já existe: $TABELA"
else
  aws dynamodb create-table \
    --table-name "$TABELA" \
    --attribute-definitions AttributeName=chave,AttributeType=S \
    --key-schema AttributeName=chave,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  echo "Criada: $TABELA"
fi
aws dynamodb wait table-exists --table-name "$TABELA"
TABELA_ARN="$(aws dynamodb describe-table --table-name "$TABELA" --query Table.TableArn --output text)"

passo "4/7 Log group do CloudWatch (retenção de 14 dias)"
if ! saida="$(aws logs create-log-group --log-group-name "$LOG_GROUP" 2>&1)"; then
  grep -q ResourceAlreadyExistsException <<<"$saida" || { echo "$saida" >&2; exit 1; }
fi
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 14

passo "5/7 Role IAM com privilégio mínimo"
CONFIANCA='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'
PERMISSOES="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Sid\": \"LerOriginais\",
      \"Effect\": \"Allow\",
      \"Action\": \"s3:GetObject\",
      \"Resource\": \"arn:aws:s3:::${BUCKET_ORIGINAIS}/*\"
    },
    {
      \"Sid\": \"IdentificarObjetoInexistente\",
      \"Effect\": \"Allow\",
      \"Action\": \"s3:ListBucket\",
      \"Resource\": \"arn:aws:s3:::${BUCKET_ORIGINAIS}\"
    },
    {
      \"Sid\": \"GravarMiniaturas\",
      \"Effect\": \"Allow\",
      \"Action\": \"s3:PutObject\",
      \"Resource\": \"arn:aws:s3:::${BUCKET_MINIATURAS}/*\"
    },
    {
      \"Sid\": \"GravarMetadados\",
      \"Effect\": \"Allow\",
      \"Action\": \"dynamodb:PutItem\",
      \"Resource\": \"${TABELA_ARN}\"
    },
    {
      \"Sid\": \"EscreverLogs\",
      \"Effect\": \"Allow\",
      \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"],
      \"Resource\": \"arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*\"
    }
  ]
}"
if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  echo "Já existe: $ROLE"
else
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "$CONFIANCA" >/dev/null
  aws iam wait role-exists --role-name "$ROLE"
  echo "Criada: $ROLE"
fi
aws iam put-role-policy --role-name "$ROLE" \
  --policy-name "$POLITICA" --policy-document "$PERMISSOES"
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

passo "6/7 Função Lambda"
VARIAVEIS="Variables={BUCKET_MINIATURAS=${BUCKET_MINIATURAS},TABELA_METADADOS=${TABELA},TAMANHO_MINIATURA=${TAMANHO_MINIATURA}}"
if aws lambda get-function --function-name "$FUNCAO" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCAO" \
    --zip-file "$ZIP" --architectures "$ARQUITETURA" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCAO"
  aws lambda update-function-configuration --function-name "$FUNCAO" \
    --runtime "$RUNTIME" --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --memory-size "$MEMORIA" --timeout "$TIMEOUT" \
    --environment "$VARIAVEIS" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCAO"
  echo "Atualizada: $FUNCAO"
else
  # Uma role recém-criada leva alguns segundos para se propagar no IAM
  for tentativa in $(seq 1 12); do
    if saida="$(aws lambda create-function \
        --function-name "$FUNCAO" \
        --runtime "$RUNTIME" --architectures "$ARQUITETURA" \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --zip-file "$ZIP" \
        --memory-size "$MEMORIA" --timeout "$TIMEOUT" \
        --environment "$VARIAVEIS" 2>&1)"; then
      break
    fi
    if [[ "$tentativa" -lt 12 ]] && grep -q "cannot be assumed" <<<"$saida"; then
      echo "Aguardando propagação da role (tentativa $tentativa)..."
      sleep 5
    else
      echo "$saida" >&2
      exit 1
    fi
  done
  aws lambda wait function-active-v2 --function-name "$FUNCAO"
  echo "Criada: $FUNCAO"
fi
FUNCAO_ARN="$(aws lambda get-function --function-name "$FUNCAO" \
  --query Configuration.FunctionArn --output text)"

passo "7/7 Gatilho S3 (ObjectCreated)"
# Recria a permissão para o S3 invocar a função (restrita a este bucket e conta)
aws lambda remove-permission --function-name "$FUNCAO" \
  --statement-id permitir-s3 >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$FUNCAO" \
  --statement-id permitir-s3 \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${BUCKET_ORIGINAIS}" \
  --source-account "$ACCOUNT_ID" >/dev/null

# Atenção: este comando substitui todas as notificações do bucket de originais
aws s3api put-bucket-notification-configuration \
  --bucket "$BUCKET_ORIGINAIS" \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"Id\": \"gerar-miniatura\",
      \"LambdaFunctionArn\": \"${FUNCAO_ARN}\",
      \"Events\": [\"s3:ObjectCreated:*\"]
    }]
  }"

cat <<FIM

Implantação concluída.
  Originais  : s3://$BUCKET_ORIGINAIS
  Miniaturas : s3://$BUCKET_MINIATURAS
  Tabela     : $TABELA
  Função     : $FUNCAO

Teste com: ./scripts/test.sh
FIM
