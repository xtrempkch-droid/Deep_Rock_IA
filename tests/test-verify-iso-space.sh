#!/usr/bin/env bash
#
# tests/test-verify-iso-space.sh — o verificador NÃO pode quebrar por falta de
# espaço no diretório temporário
# -----------------------------------------------------------------------------
# Por que este teste existe (bug real, sessão #36):
#
#   O verificador extraía o MODELO INTEIRO da ISO para conferir o "magic" GGUF.
#   Com `--iso-model auto` isso significa 1,1 GB — e `mktemp -d` usa /tmp, que
#   em muitas máquinas é **tmpfs** (RAM). O /tmp enchia NO MEIO da verificação
#   e, a partir do primeiro ENOSPC, TODA extração seguinte falhava. O resultado
#   era uma cascata de falsos "AUSENTE"/"FAIL" que culpava a ISO ("rede auto
#   sem o netplan") por um problema de ESPAÇO.
#
#   Pior: o dono receberia "[ERROR] A ISO gerada NÃO passou na verificação" com
#   uma ISO perfeitamente boa.
#
# O que é provado aqui:
#   1. o verificador aceita `--tmp DIR` e usa ESSE diretório;
#   2. com um modelo GIGANTE (esparso, custo zero em disco), ele confere o
#      "magic" sem copiar o arquivo inteiro (tempo e espaço constantes);
#   3. um modelo com magic errado continua sendo REPROVADO (a economia de
#      espaço não pode cegar a checagem);
#   4. `--tmp` num caminho inválido não explode: cai no próximo com espaço.
#
# Requer: bash, coreutils, gzip, xorriso? NÃO — usa `--dir` (árvore extraída).
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly VERIFIER="${TEST_ROOT}/iso/verify-iso.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# Árvore mínima de ISO com um modelo .gguf do tamanho pedido.
# `truncate` cria ESPARSO: 2 GB "de graça" (sem ocupar 2 GB no disco).
mk_tree() {
  local d="$1" model="$2" magic="${3:-GGUF}"
  rm -rf "$d"
  mkdir -p "$d/models" "$d/preseed" "$d/casper"
  truncate -s 2147483648 "$d${model}"
  # Escreve o magic nos 4 primeiros bytes do arquivo esparso.
  printf '%s' "$magic" | dd of="$d${model}" bs=1 seek=0 conv=notrunc status=none
  printf 'x' > "$d/casper/vmlinuz"
}

run() {
  local tree="$1"; shift
  bash "$VERIFIER" --dir "$tree" --distro ubuntu "$@" 2>&1 || true
}

MODEL="/models/big-Q4_K_M.gguf"

echo "verificador × espaço em disco (modelo esparso de 2 GB)"

# --- 1. --tmp é respeitado ----------------------------------------------
tree="${WORK}/t1"; mk_tree "$tree" "$MODEL"
tmpd="${WORK}/meutmp"; mkdir -p "$tmpd"
out="$(run "$tree" --tmp "$tmpd")"
if compgen -G "${tmpd}/*" >/dev/null; then
  ok "--tmp DIR é usado de verdade para os arquivos inspecionados"
else
  bad "--tmp DIR foi ignorado (nada foi criado ali)"
fi
if grep -q 'GGUF v' <<< "$out"; then
  ok "modelo esparso de 2 GB validado como GGUF"
else
  bad "o modelo de 2 GB não foi validado (a checagem do magic se perdeu?)"
fi

# --- 2. Não copia o arquivo inteiro (o ponto do bug) --------------------
# Se copiasse 2 GB, o diretório temporário passaria de ~2 GB. Conferimos que
# ficou ORDENS DE GRANDEZA menor (o cabeçalho de 2 KB).
biggest="$(du -sb "$tmpd" 2>/dev/null | awk '{print $1}')"
[[ -n "$biggest" ]] || biggest=0
if (( biggest < 104857600 )); then
  ok "não copia o modelo inteiro (temp: $((biggest/1024)) KiB, não ~2 GiB)"
else
  bad "copiou o modelo inteiro para o temporário ($((biggest/1024/1024)) MiB) — enche o /tmp"
fi

# --- 3. A economia de espaço NÃO cega a validação -----------------------
tree="${WORK}/t2"; mk_tree "$tree" "$MODEL" "XXXX"
out="$(run "$tree" --tmp "${WORK}/tmp2")"
if grep -q "magic 'XXXX' em vez de 'GGUF'" <<< "$out"; then
  ok "modelo com magic errado continua REPROVADO (não virou passe livre)"
else
  bad "modelo inválido passou (a checagem do magic foi afrouxada demais)"
fi

# --- 4. --tmp inválido não derruba: cai no próximo com espaço -----------
tree="${WORK}/t3"; mk_tree "$tree" "$MODEL"
out="$(run "$tree" --tmp /caminho/que/nao/existe/nem/tem/espaco)"
if grep -q 'GGUF v' <<< "$out"; then
  ok "--tmp inválido degrada (usa o próximo com espaço), não falha"
else
  bad "--tmp inválido derrubou a verificação"
fi

# --- 5. Regressão: o diretório de trabalho nunca é escolhido às cegas ---
if grep -q 'df -Pk' "$VERIFIER"; then
  ok "o verificador confere ESPAÇO antes de escolher o diretório de trabalho"
else
  bad "o verificador não confere espaço (volta a quebrar em /tmp pequeno)"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "verify-iso-space: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "verify-iso-space: PASS=${PASS} FAIL=${FAIL}"
exit 1
