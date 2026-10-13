#!/usr/bin/env bash
#
# tests/test-iso-repo-filter.sh — prova o download do repositório apt local
# -----------------------------------------------------------------------------
# Reproduz OFFLINE o bug que quebrou a ISO Ubuntu + `air_gapped=true` no CI:
#
#   [ERROR] Pacote pedido está AUSENTE no repositório: gnupg
#   [ERROR] Pacote pedido está AUSENTE no repositório: jq
#   [ERROR] Pacote pedido está AUSENTE no repositório: git
#
# Causa MEDIDA: `apt-get download a b c` **aborta o lote inteiro** quando UM dos
# nomes não tem candidato — não baixa nem os válidos. Verificado na máquina de
# desenvolvimento:
#
#     apt-get download git PACOTE-QUE-NAO-EXISTE jq  →  rc=100, ZERO arquivos
#
# O script baixava em lotes de 25 com `|| true`, então cada lote que continha
# uma "isca" (pacote virtual, que varia com a release do host) perdia até 25
# pacotes em SILÊNCIO. `gnupg`, `jq` e `git` estavam no lote da isca.
#
# Como testar isso sem rede nem apt de verdade: `apt-cache` e `apt-get` são
# SUBSTITUÍDOS por funções do shell. O subshell `( cd ... && apt-get ... )` do
# script herda as funções, então o stub é usado de verdade — e o stub REPRODUZ o
# comportamento medido (aborta o lote se houver isca).
#
# O que este teste prova:
#   1. o filtro descarta nomes sem candidato (a isca) ANTES de baixar;
#   2. o fallback um-a-um recupera os vizinhos de lote quando a falha acontece;
#   3. a falha NÃO é engolida em silêncio (aparece no log, com o nome);
#   4. se o parser do apt-cache não reconhecer a saída, o script DEGRADA
#      (segue sem filtrar) em vez de baixar nada.
#
# Uso: bash tests/test-iso-repo-filter.sh [--verbose]
# Não precisa de root, rede, apt real nem xorriso. Exit 1 se algo falhar.
# -----------------------------------------------------------------------------

set -euo pipefail

# Nomes que NÃO podem colidir com os `readonly` do iso/build-iso.sh
# (REPO_ROOT, ISO_DIR...): já quebrou uma vez em families/resolve.sh.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly BUILD_ISO="${TEST_ROOT}/iso/build-iso.sh"
readonly POLICY_FIXTURE="${TEST_DIR}/fixtures/apt-cache-policy.txt"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

# assert <descrição> <esperado> <obtido>
assert() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else
    bad "$1"; echo "        esperado: '$2'"; echo "        obtido:   '$3'"
  fi
}

# shellcheck source=/dev/null
source "$BUILD_ISO"

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
# `apt-get` é um EXECUTÁVEL em PATH, não uma função: a versão antiga do script
# chamava `xargs ... sh -c 'apt-get download ...'`, e um `sh` novo NÃO herda
# funções do shell do teste — o teste acabava chamando o apt-get DE VERDADE
# (baixou pacote real na primeira execução). Um executável em PATH intercepta
# os dois desenhos, então o teste mede o código, não o mecanismo de injeção.
#
# `apt-cache` fica como função: ele só é chamado por substituição de comando,
# que herda funções de forma confiável.
DEPENDS_LIST=""   # preenchido por cada cenário
ISCA=""           # nome que faz o lote falhar (o "pacote virtual")

mkdir -p "$WORK/bin"
cat > "$WORK/bin/apt-get" <<'STUB'
#!/bin/sh
# Stub de `apt-get download`: reproduz o comportamento MEDIDO do apt real —
# UM nome ruim (sem candidato) ABORTA O LOTE INTEIRO, sem baixar nem os válidos.
[ "${1:-}" = "download" ] || exit 0
shift
for p in "$@"; do
  if [ -n "${STUB_ISCA:-}" ] && [ "$p" = "$STUB_ISCA" ]; then
    echo "E: Não é possível encontrar o pacote ${STUB_ISCA}" >&2
    exit 100
  fi
done
for p in "$@"; do : > "${p}_1.0_amd64.deb"; done
exit 0
STUB
chmod +x "$WORK/bin/apt-get"
export PATH="${WORK}/bin:${PATH}"
export STUB_ISCA=""

apt-cache() {
  case "${1:-}" in
    depends) printf '%s\n' "$DEPENDS_LIST" ;;
    policy)  cat "$POLICY_FIXTURE" ;;
    *)       return 0 ;;
  esac
}

# Descobre o que existe no pool do cenário
pool_names() {
  local d="$1"
  find "$d/pool" -maxdepth 1 -name '*.deb' -printf '%f\n' 2>/dev/null \
    | sed 's/_.*//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

run_download() {
  local dest="$1"
  rm -rf "$dest"; mkdir -p "$dest"
  export STUB_ISCA="$ISCA"
  download_repo_packages "$dest" "git jq gnupg libopenblas-dev" 2>&1
}

echo "Download do repositório apt local (stubs; sem rede)"

# ---------------------------------------------------------------------------
# Cenário 1: a ISCA não tem candidato -> o FILTRO tem de descartá-la
# ---------------------------------------------------------------------------
echo
echo "1) isca SEM candidato (mail-transport-agent) — o caso do CI"
DEPENDS_LIST="mail-transport-agent
git
jq
gnupg
libopenblas-dev"
ISCA="mail-transport-agent"
out="$(run_download "$WORK/c1")"

assert "isca é descartada antes do download" "" "$(pool_names "$WORK/c1" | tr ' ' '\n' | grep -x 'mail-transport-agent' || true)"
assert "todos os 4 válidos foram baixados" "git gnupg jq libopenblas-dev" "$(pool_names "$WORK/c1")"
# O filtro tem de agir ANTES do download: sem aviso de pacote não baixado.
# (Não dá para contar invocações do stub: ele roda em subshell — a variável
# incrementada lá dentro não volta para o shell do teste.)
case "$out" in
  *"não puderam ser baixados"*) bad "o filtro não evitou a falha (o fallback é que salvou)" ;;
  *) ok "o filtro evitou a falha antes de baixar" ;;
esac
case "$out" in
  *"virtual/ausente descartado"*) ok "o descarte é registrado no log" ;;
  *) bad "o descarte NÃO aparece no log"; echo "$out" | tail -5 | sed 's/^/        /' ;;
esac

# ---------------------------------------------------------------------------
# Cenário 2: a falha ACONTECE mesmo assim -> o fallback tem de isolar
# ---------------------------------------------------------------------------
# Aqui a isca TEM candidato (então o filtro a mantém), mas o download do lote
# falha mesmo assim. O fallback um-a-um tem de salvar os vizinhos.
echo
echo "2) isca COM candidato (gnupg) — o lote falha e o fallback isola"
DEPENDS_LIST="git
jq
gnupg
libopenblas-dev"
ISCA="gnupg"
out="$(run_download "$WORK/c2")"

assert "os vizinhos de lote sobreviveram" "git jq libopenblas-dev" "$(pool_names "$WORK/c2")"
assert "só a isca ficou de fora" "" "$(pool_names "$WORK/c2" | tr ' ' '\n' | grep -x 'gnupg' || true)"
case "$out" in
  *"não puderam ser baixados"*) ok "a falha é reportada (não engolida)" ;;
  *) bad "a falha foi engolida em silêncio"; echo "$out" | tail -5 | sed 's/^/        /' ;;
esac
case "$out" in
  *gnupg*) ok "o nome que falhou aparece no log" ;;
  *) bad "o log não diz QUAL pacote falhou" ;;
esac

# ---------------------------------------------------------------------------
# Cenário 3: parser não reconhece a saída -> DEGRADA (não baixa nada)
# ---------------------------------------------------------------------------
echo
echo "3) apt-cache policy devolve lixo — tem de degradar, não zerar"
DEPENDS_LIST="git
jq
gnupg
libopenblas-dev"
ISCA="gnupg"
# ---------------------------------------------------------------------------
# O stub de policy passa a devolver algo que o parser NÃO entende.
apt-cache() {
  case "${1:-}" in
    depends) printf '%s\n' "$DEPENDS_LIST" ;;
    policy)  echo "saída inesperada de outra versão do apt" ;;
    *)       return 0 ;;
  esac
}
out="$(run_download "$WORK/c3")"
assert "mesmo sem filtro, os válidos chegam (via fallback)" "git jq libopenblas-dev" "$(pool_names "$WORK/c3")"
case "$out" in
  *"não devolvi o fecho"*|*"não vou descartar o fecho"*) ok "o degrade avisa no log" ;;
  *) bad "o degrade foi silencioso"; echo "$out" | tail -5 | sed 's/^/        /' ;;
esac

# ---------------------------------------------------------------------------
# Unitário: packages_with_candidate contra a fixture REAL do apt-cache policy
# ---------------------------------------------------------------------------
echo
echo "4) packages_with_candidate contra a saída REAL do apt-cache policy"
# A fixture é a saída verdadeira de:
#   LC_ALL=C apt-cache policy git jq gnupg mail-transport-agent libopenblas-dev
apt-cache() { cat "$POLICY_FIXTURE"; }
got="$(packages_with_candidate "$(printf 'git\njq\ngnupg\nmail-transport-agent\nlibopenblas-dev\n')")"
assert "mantém quem tem candidato" "git
gnupg
jq
libopenblas-dev" "$(printf '%s\n' "$got" | sort)"
assert "descarta o virtual (Candidate: (none))" "" "$(printf '%s\n' "$got" | grep -x 'mail-transport-agent' || true)"
assert "entrada vazia -> saída vazia" "" "$(packages_with_candidate "")"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "iso-repo-filter: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "iso-repo-filter: PASS=${PASS} FAIL=${FAIL}"
exit 1
