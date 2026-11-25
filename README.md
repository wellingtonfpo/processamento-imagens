# Processamento de arquivos: miniaturas com AWS Lambda

```
Usuário ──foto──▶ S3: originais ──ObjectCreated──▶ Lambda ──┬──▶ S3: miniaturas  (imagem reduzida)
                                                            └──▶ DynamoDB        (metadados)
```

## Estrutura

```
src/lambda_function.py   código da função (Python 3.14 + Pillow)
scripts/config.sh        nomes e parâmetros compartilhados
scripts/build.sh         gera build/funcao.zip
scripts/deploy.sh        cria/atualiza toda a infraestrutura via AWS CLI
scripts/test.sh          teste ponta a ponta
scripts/destroy.sh       remove tudo
tests/                   testes locais (não usam a nuvem)
exemplos/foto.jpg        foto de exemplo
```

## Pré-requisitos

O caminho mais simples é o **AWS CloudShell** (terminal no console da AWS), que já traz a CLI
autenticada e o Python. Envie o .zip em *Actions → Upload file*.

Em máquina própria (Linux, macOS ou Windows com WSL):

- AWS CLI v2 configurada (`aws configure` ou `aws sso login`)
- Python 3 com pip
- Permissão para gerenciar S3, DynamoDB, Lambda, IAM (roles) e CloudWatch Logs

Não é preciso Docker.

## Uso

```bash
unzip processamento-imagens.zip && cd processamento-imagens

export AWS_REGION=sa-east-1            # opcional (São Paulo)
aws sts get-caller-identity            # confira a conta antes de implantar

bash scripts/deploy.sh                 # implanta
bash scripts/test.sh                   # testa com a foto de exemplo
bash scripts/test.sh ~/minha-foto.png  # ou com uma foto sua
bash scripts/destroy.sh                # remove tudo (pede confirmação)
```

Use sempre os mesmos `AWS_REGION` e `PROJETO` nos três scripts.

O `deploy.sh` pode ser executado novamente: ele reaproveita o que já existe e publica o código novo.

### Enviar uma foto manualmente

```bash
CONTA=$(aws sts get-caller-identity --query Account --output text)
aws s3 cp foto.jpg "s3://fotos-originais-${CONTA}-${AWS_REGION}/foto.jpg"
aws dynamodb get-item --table-name fotos-metadados --key '{"chave":{"S":"foto.jpg"}}'
```

### Ver os logs

```bash
aws logs tail /aws/lambda/fotos-gerar-miniatura --since 10m --follow
```

## O que é criado

| Ordem | Recurso | Nome (padrão) | Comando principal |
|---|---|---|---|
| 1 | Pacote de código | `build/funcao.zip` | `pip install --target` |
| 2 | 2 buckets S3 privados | `fotos-originais-…`, `fotos-miniaturas-…` | `s3api create-bucket` |
| 3 | Tabela DynamoDB sob demanda | `fotos-metadados` | `dynamodb create-table` |
| 4 | Log group (14 dias) | `/aws/lambda/fotos-gerar-miniatura` | `logs create-log-group` |
| 5 | Role IAM com privilégio mínimo | `fotos-lambda-role-<região>` | `iam create-role`, `put-role-policy` |
| 6 | Função Lambda (arm64) | `fotos-gerar-miniatura` | `lambda create-function` |
| 7 | Gatilho `s3:ObjectCreated:*` | | `lambda add-permission`, `s3api put-bucket-notification-configuration` |

## Configuração

| Variável | Padrão | Descrição |
|---|---|---|
| `PROJETO` | `fotos` | prefixo dos recursos (3 a 20 caracteres) |
| `AWS_REGION` | região da CLI ou `us-east-1` | região |
| `TAMANHO_MINIATURA` | `256` | maior lado da miniatura, em pixels |
| `MEMORIA` | `512` | MB |
| `TIMEOUT` | `30` | segundos |
| `ARQUITETURA` | `arm64` | ou `x86_64` |
| `RUNTIME` | `python3.14` | runtime do Lambda |

Exemplo: `TAMANHO_MINIATURA=400 bash scripts/deploy.sh`

## Comportamento

- Aceita JPEG, PNG, WebP e GIF, identificados pelo conteúdo. GIF animado gera miniatura do 1º quadro.
- Mantém proporção e formato, não amplia imagens pequenas e corrige a rotação (EXIF).
- A miniatura não leva EXIF, portanto não expõe a localização GPS.
- Limites: 20 MB e 40 megapixels (variáveis `MAX_BYTES` e `MAX_PIXELS` no código/ambiente).
- Arquivo inválido: gravado no DynamoDB com `status = ERRO`, sem novas tentativas.
- Falha temporária de serviço: o Lambda tenta mais 2 vezes (padrão de invocação assíncrona).
- Reenviar o mesmo nome sobrescreve a miniatura e o registro.
- Buckets separados evitam o loop em que a função dispara a si mesma.

## Testes locais

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt
python -m pytest tests -q
```

## Para produção

- Fila de falhas (SQS como destino `OnFailure`) e alarme no CloudWatch.
- Envio direto pelo navegador com URL pré-assinada do S3.
- Infraestrutura como código (AWS SAM, CloudFormation, CDK ou Terraform).
- Regras de ciclo de vida do S3 para controlar o custo de armazenamento.
