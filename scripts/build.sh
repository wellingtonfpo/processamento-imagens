#!/usr/bin/env bash
# Gera build/funcao.zip com o código e a Pillow compilada para o Linux do Lambda.
# Funciona em Linux, macOS e AWS CloudShell, sem Docker.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME="${RUNTIME:-python3.14}"
ARQUITETURA="${ARQUITETURA:-arm64}"

case "$ARQUITETURA" in
  arm64)  CPU="aarch64" ;;
  x86_64) CPU="x86_64" ;;
  *) echo "ARQUITETURA inválida: $ARQUITETURA (use arm64 ou x86_64)" >&2; exit 1 ;;
esac

rm -rf "$RAIZ/build"
mkdir -p "$RAIZ/build/pacote"

python3 -m pip install \
  --quiet --disable-pip-version-check \
  --target "$RAIZ/build/pacote" \
  --platform "manylinux2014_${CPU}" \
  --platform "manylinux_2_28_${CPU}" \
  --implementation cp \
  --python-version "${RUNTIME#python}" \
  --only-binary=:all: \
  -r "$RAIZ/requirements.txt"

cp "$RAIZ/src/lambda_function.py" "$RAIZ/build/pacote/"
# O Lambda precisa de permissão de leitura em todos os arquivos
chmod -R u=rwX,go=rX "$RAIZ/build/pacote"

(cd "$RAIZ/build/pacote" && python3 -m zipfile -c ../funcao.zip ./*)

echo "Pacote gerado: build/funcao.zip ($(du -h "$RAIZ/build/funcao.zip" | cut -f1))"
