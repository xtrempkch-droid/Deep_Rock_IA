#!/usr/bin/env bash
#
# tests/test-iso-selection.sh — prova a escolha da ISO oficial no SHA256SUMS
# -----------------------------------------------------------------------------
# Roda as MESMAS funções que o build usa (pick_iso_entry, pick_iso_entry_by_name
# e normalize_iso_name, de iso/build-iso.sh) contra SHA256SUMS REAIS guardados
# em tests/fixtures/.
#
# Por que existe: a geração da ISO Ubuntu morria com `exit code 22` do curl —
# sem nenhuma pista do motivo — porque o SHA256SUMS do Ubuntu tem DUAS
# particularidades:
#
#   1. Marca o modo BINÁRIO com `*` antes do nome (mesmo formato do
#      `md5sum -b`). Sem remover o `*`, a URL sai como
#      `.../24.04/*ubuntu-24.04.5-live-server-amd64.iso` → HTTP 404, que o
#      `curl -f` transforma em `exit 22`.
#   2. Lista TODAS as point releases (24.04.3, .4, .5…) e as variantes
#      desktop/wsl. Pegar a PRIMEIRA entrada casada baixaria a versão mais
#      VELHA em vez da atual.
#
# Nenhum dos dois aparece com um SHA256SUMS inventado de duas linhas — por isso
# as fixtures são cópias fiéis dos arquivos oficiais (capturadas em 2026-10-12
# de releases.ubuntu.com/24.04/SHA256SUMS. A fixture do Debian continua em
# tests/fixtures/ apenas como histórico (o caminho Debian saiu — ADR-001).
#
# Uso:
#   bash tests/test-iso-selection.sh
#   bash tests/test-iso-selection.sh --verbose
#
# Não precisa de root, de hardware, de rede nem de xorriso. Exit 1 se qualquer
# asserção falhar.
# -----------------------------------------------------------------------------

set -euo pipefail

# ATENÇÃO aos nomes das variáveis: `iso/build-iso.sh` declara `ISO_DIR` e
# `REPO_ROOT` como `readonly`, então usar esses nomes aqui ABORTA o `source`
# ("readonly variable"). Já aconteceu antes com `FAMILIES_DIR` em
# families/resolve.sh — é a mesma armadilha, agora registrada no JOURNAL § 6.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly BUILD_ISO="${TEST_ROOT}/iso/build-iso.sh"
readonly FIXTURES_DIR="${TEST_DIR}/fixtures"

VERBOSE=0
# `$'...'` (ANSI-C) coloca os escapes de verdade na variável, então um `echo`
# simples já colore — sem depender de `echo -e` (que não é POSIX e muda entre
# bash/sh).
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_OK=""; C_ERR=""; C_BOLD=""
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose|-v) VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

# Carrega as funções SEM executar o build (o build-iso.sh tem guarda de main).
# shellcheck source=/dev/null
source "$BUILD_ISO"

PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ${C_OK}ok${C_RESET}   $1"; return 0; }
bad()  { FAIL=$((FAIL + 1)); echo "  ${C_ERR}FALHOU${C_RESET} $1"; return 0; }

# check <descrição> <esperado> <obtido>
check() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then ok "$desc"; else
    bad "$desc"
    echo "        esperado: '$want'"
    echo "        obtido:   '$got'"
  fi
}

echo "${C_BOLD}Escolha da ISO oficial (SHA256SUMS)${C_RESET}"

# --- Ubuntu: o caso que quebrava -------------------------------------------
U_SUMS="${FIXTURES_DIR}/SHA256SUMS.ubuntu-24.04"
u_entry="$(pick_iso_entry "$U_SUMS" "$UBUNTU_ISO_PATTERN")"
u_sha="${u_entry%% *}"
u_name="${u_entry##* }"

check "ubuntu: escolhe a live-server" \
  "ubuntu-24.04.5-live-server-amd64.iso" "$u_name"
check "ubuntu: escolhe a MAIOR versão (não a primeira)" \
  "97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8" "$u_sha"

# O bug de origem: o `*` do modo binário ia para dentro da URL (`exit code 22`).
case "$u_name" in
  \**) bad "ubuntu: o nome NÃO pode começar com '*' (era a causa do HTTP 404)" ;;
  *)   ok  "ubuntu: o nome NÃO começa com '*' (o 404 vinha daqui)" ;;
esac

# E o nome tem de ser um nome de arquivo simples — é o que a URL exige.
if [[ "$u_name" =~ ^[A-Za-z0-9._-]+\.iso$ ]]; then
  ok "ubuntu: nome é utilizável numa URL"
else
  bad "ubuntu: nome inválido para URL: '$u_name'"
fi

# Não pode casar desktop nem wsl do mesmo arquivo.
case "$u_name" in
  *desktop*|*wsl*) bad "ubuntu: casou uma variante desktop/wsl" ;;
  *)               ok  "ubuntu: ignora as variantes desktop e wsl" ;;
esac


# --- --iso-url: casamento por nome exato ------------------------------------
by_name="$(pick_iso_entry_by_name "$U_SUMS" "ubuntu-24.04.4-live-server-amd64.iso")"
check "--iso-url: acha o nome exato informado" \
  "ubuntu-24.04.4-live-server-amd64.iso" "${by_name##* }"
by_name_seems_wrong="$(pick_iso_entry_by_name "$U_SUMS" "ubuntu-24.04.9-live-server-amd64.iso")"
check "--iso-url: nome inexistente devolve vazio" "" "$by_name_seems_wrong"

# --- normalize_iso_name: os dois marcadores ---------------------------------
check "normalize: remove o marcador binário '*'" \
  "ubuntu-24.04.5-live-server-amd64.iso" "$(normalize_iso_name '*ubuntu-24.04.5-live-server-amd64.iso')"
check "normalize: remove o prefixo './'" \
  "ubuntu-24.04.5-live-server-amd64.iso" "$(normalize_iso_name './ubuntu-24.04.5-live-server-amd64.iso')"
check "normalize: nome limpo passa intacto" \
  "ubuntu-24.04.5-live-server-amd64.iso" "$(normalize_iso_name 'ubuntu-24.04.5-live-server-amd64.iso')"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "${C_OK}iso-selection: PASS=${PASS} FAIL=0${C_RESET}"
  exit 0
fi
echo "${C_ERR}iso-selection: PASS=${PASS} FAIL=${FAIL}${C_RESET}"
exit 1
