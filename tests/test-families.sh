#!/usr/bin/env bash
#
# tests/test-families.sh — prova o casamento CPU → família sem precisar do CPU
# -----------------------------------------------------------------------------
# Roda a MESMA função que o build usa (pick_family, de families/resolve.sh)
# contra o corpus de nomes reais em tests/families-matrix.txt e diz se cada um
# caiu na família esperada.
#
# Por que existe: o pedido foi "já deixe pronto o suporte [a Zen 3/4]". Sem o
# hardware, a parte do suporte que PODE ser provada é a regra de seleção — e é
# exatamente onde os erros moram: um regex largo demais manda um Ryzen 8000
# (Zen 4) para o `generic`, e um largo de menos deixa um Zen 3 sem família.
# ISA e -march em execução só o hardware prova (ver docs/FAMILIES.md § 9).
#
# Uso:
#   bash tests/test-families.sh              # roda o corpus
#   bash tests/test-families.sh --verbose    # mostra também os que passaram
#   bash tests/test-families.sh --list       # só imprime o corpus
#
# Não precisa de root, de hardware específico nem de rede. Exit 1 se houver
# qualquer divergência.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly RESOLVE_SH="${REPO_ROOT}/families/resolve.sh"
readonly MATRIX="${SCRIPT_DIR}/families-matrix.txt"

VERBOSE=0; LIST_ONLY=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_OK="\033[32m"; C_ERR="\033[31m"; C_WARN="\033[33m"; C_INFO="\033[36m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_OK=""; C_ERR=""; C_WARN=""; C_INFO=""; C_BOLD=""
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    --list)       LIST_ONLY=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '[erro] argumento desconhecido: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ -f "$RESOLVE_SH" ]] || { printf '[erro] não encontrei %s\n' "$RESOLVE_SH" >&2; exit 2; }
[[ -f "$MATRIX" ]]     || { printf '[erro] não encontrei %s\n' "$MATRIX" >&2; exit 2; }

if [[ $LIST_ONLY -eq 1 ]]; then
  grep -vE '^[[:space:]]*(#|$)' "$MATRIX"
  exit 0
fi

# Carrega o resolvedor (ele tem guarda de fonte, não executa nada).
# shellcheck source=/dev/null
. "$RESOLVE_SH"

# O casamento é o que estamos exercitando; não precisamos de /proc/cpuinfo aqui.
PASS=0; FAIL=0
declare -a failures=()

printf '%b== Casamento CPU → família (corpus de modelos reais) ==%b\n\n' "$C_BOLD" "$C_RESET"

while IFS='|' read -r expected model; do
  # Ignora comentários e linhas vazias.
  [[ "$expected" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${expected// }" ]] && continue
  [[ -z "${model// }" ]] && continue

  # Normaliza espaços acidentais nas bordas (o corpus é editado à mão).
  expected="${expected#"${expected%%[![:space:]]*}"}"
  expected="${expected%"${expected##*[![:space:]]}"}"
  model="${model#"${model%%[![:space:]]*}"}"
  model="${model%"${model##*[![:space:]]}"}"

  unset FAMILY_ID FAMILY_MATCH_REASON
  pick_family "$model"

  if [[ "$FAMILY_ID" == "$expected" ]]; then
    PASS=$((PASS + 1))
    [[ $VERBOSE -eq 1 ]] && printf '  %b[ok]%b   %-21s %s\n' "$C_OK" "$C_RESET" "$FAMILY_ID" "$model"
  else
    FAIL=$((FAIL + 1))
    failures+=("esperado='${expected}' obtido='${FAMILY_ID}' :: ${model}")
    printf '  %b[FAIL]%b esperado=%-21s obtido=%s\n' "$C_ERR" "$C_RESET" "$expected" "$FAMILY_ID"
    printf '         %s\n' "$model"
    printf '         motivo: %s\n' "${FAMILY_MATCH_REASON:-<sem motivo>}"
  fi
done < "$MATRIX"

printf '\n%b== Resumo ==%b  PASS=%d  FAIL=%d  (total %d)\n' \
  "$C_BOLD" "$C_RESET" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [[ $FAIL -gt 0 ]]; then
  printf '\n%bDivergências:%b\n' "$C_WARN" "$C_RESET"
  printf '  - %s\n' "${failures[@]}"
  printf '\nDica: ao corrigir, ajuste o FAMILY_MATCH_NAME em families/<id>/family.conf\n'
  printf 'e rode de novo. Adicione ao corpus o caso real que motivou a correção.\n'
  exit 1
fi

printf '%bCasamento OK:%b nenhuma família mal atribuída no corpus.\n' "$C_OK" "$C_RESET"
printf '%bLimite deste teste:%b ele NÃO prova ISA nem -march em execução — isso só\n' "$C_INFO" "$C_RESET"
printf 'um CPU de verdade prova (ver docs/FAMILIES.md § 9).\n'
exit 0
