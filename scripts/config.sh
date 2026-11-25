# shellcheck shell=bash
# shellcheck disable=SC2034  # variáveis usadas pelos scripts que carregam este arquivo
# Configuração compartilhada pelos scripts. Não execute diretamente.
# Qualquer valor pode ser alterado por variável de ambiente, ex.:
#   PROJETO=loja AWS_REGION=sa-east-1 ./scripts/deploy.sh

export AWS_PAGER=""

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROJETO="${PROJETO:-fotos}"
if ! [[ "$PROJETO" =~ ^[a-z0-9][a-z0-9-]{1,18}[a-z0-9]$ ]]; then
  echo "PROJETO deve ter de 3 a 20 caracteres: letras minúsculas, números e hífen." >&2
  exit 1
fi

command -v aws >/dev/null || { echo "AWS CLI não encontrada." >&2; exit 1; }

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || true)}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION
export AWS_DEFAULT_REGION="$AWS_REGION"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Nomes dos recursos
BUCKET_ORIGINAIS="${PROJETO}-originais-${ACCOUNT_ID}-${AWS_REGION}"
BUCKET_MINIATURAS="${PROJETO}-miniaturas-${ACCOUNT_ID}-${AWS_REGION}"
TABELA="${PROJETO}-metadados"
FUNCAO="${PROJETO}-gerar-miniatura"
ROLE="${PROJETO}-lambda-role-${AWS_REGION}"   # IAM é global, por isso a região no nome
POLITICA="${PROJETO}-lambda-policy"
LOG_GROUP="/aws/lambda/${FUNCAO}"

# Parâmetros da função
RUNTIME="${RUNTIME:-python3.14}"
ARQUITETURA="${ARQUITETURA:-arm64}"           # arm64 ou x86_64
MEMORIA="${MEMORIA:-512}"
TIMEOUT="${TIMEOUT:-30}"
TAMANHO_MINIATURA="${TAMANHO_MINIATURA:-256}"
