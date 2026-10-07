#!/usr/bin/env bash
#
# profiles/ryzen/llama-build.sh — Compila o llama.cpp para Zen 2 (znver2)
# -----------------------------------------------------------------------------
# Wrapper fino sobre profiles/xeon/llama-build.sh: a única diferença do perfil
# ryzen é o `-march=znver2 -mtune=znver2` exigido pelo requisito do projeto
# (Zen 2, AVX2 apenas — SEM AVX-512).
#
# Este script existe para que a máquina de build também possa compilar o
# llama.cpp fora do Docker (ex.: para benchmarks locais), reutilizando toda a
# validação de ISA e o fallback seguro do script base.
#
# Uso:
#   bash profiles/ryzen/llama-build.sh [--dry-run] [--yes] [--dir DIR] [--jobs N] [--ref REF]
#
# Idempotente (delegado ao script base).
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
BASE_BUILD="${SCRIPT_DIR}/../xeon/llama-build.sh"

# Zen 2: -march=znver2 habilita as instruções e o modelo de cache corretos.
# NUNCA adicionar -mavx512* aqui: o Ryzen 5 3500X não possui AVX-512.
readonly MARCH_FLAGS="-march=znver2 -mtune=znver2"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_ERR="\033[31m"
else
  C_RESET=""; C_INFO=""; C_ERR=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR" "$(_ts)" "$*" "$C_RESET" >&2; }

if [[ ! -f "$BASE_BUILD" ]]; then
  log_error "Script base não encontrado: ${BASE_BUILD}"
  exit 1
fi

log_info "Perfil ryzen: compilando com '${MARCH_FLAGS}'."
log_info "Delegando para ${BASE_BUILD}"

# Repassa todos os argumentos + as flags de arquitetura do Zen 2.
exec bash "$BASE_BUILD" "$@" --march "$MARCH_FLAGS"
