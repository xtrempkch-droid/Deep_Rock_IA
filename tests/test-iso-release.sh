#!/usr/bin/env bash
#
# tests/test-iso-release.sh — prova a conferência de RELEASE do --iso-repo auto
# -----------------------------------------------------------------------------
# Por que este teste existe (bug real, sessão #36):
#
#   `--iso-repo auto` embute na mídia os .deb que a instalação precisa (inclusive
#   o `openssh-server` e o `sudo`). É isso que torna a ISO capaz de instalar SEM
#   rede — e sem rede a instalação falha em silêncio em dois pontos: não instala
#   o SSH e não instala os pacotes. Embutir .deb de OUTRA release é pior que não
#   embutir nada (dependências não casam e a instalação quebra), então o build
#   confere a release da base contra a da máquina que gera a ISO.
#
#   Dois defeitos nessa conferência:
#     (a) com `--iso <arquivo>`, a versão da base vinha do DEFAULT (24.04) e não
#         do arquivo. Gerar uma ISO 26.04 local num host 26.04 dava
#         "Release incompatível" e o repositório local era DESCARTADO.
#     (b) o codename saía de uma tabela fixa. Release nova (26.04) → "" →
#         o build seguia em "não confiro a release" e podia embutir .deb
#         errados sem nenhum aviso.
#
# O que é provado (com arquivos ISO FALSOS — nenhuma ISO real é lida/escrita):
#   1. a versão sai do NOME do arquivo (26.04 reconhecido como 26.04);
#   2. release que CASA com a máquina → "Release confere" e o repo é montado;
#   3. release que NÃO casa → AVISO explícito e repo descartado (não silencioso);
#   4. nome fora do padrão → não explode, degrada com aviso;
#   5. `--iso-repo none` nunca tenta montar repositório.
#
# Requer: bash, sed, coreutils. Sem rede, sem xorriso, sem root.
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
readonly BUILD="iso/build-iso.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

HOST_CN="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
readonly HOST_CN

# Uma ISO FALSA: o gerador só confere que o arquivo existe em dry-run.
fake_iso() {
  local name="$1"
  : > "${WORK}/${name}"
  printf '%s' "${WORK}/${name}"
}

# Roda o gerador em dry-run com uma ISO falsa e devolve a saída.
dry() {
  local iso="$1"; shift
  bash "$BUILD" --dry-run --yes --distro ubuntu --iso "$iso" --disk auto \
       --password-hash '$6$x$y' "$@" 2>&1 || true
}

echo "conferência de release do --iso-repo auto (host: ${HOST_CN:-?})"

# --- 1. A versão sai do NOME do arquivo ----------------------------------
# 22.04 é a release mais antiga da tabela: se o código ainda usasse o default
# (24.04), uma ISO 22.04 jamais daria "reconheci 22.04".
iso2204="$(fake_iso ubuntu-22.04.99-live-server-amd64.iso)"
out="$(dry "$iso2204" --iso-repo none)"
if grep -q 'ISO local' <<< "$out"; then
  ok "aceita uma ISO local pelo caminho (--iso)"
else
  bad "não aceitou a ISO local em --dry-run"
fi

# Com uma release que NÃO é a do host, a mensagem tem de citar a release da ISO.
iso_outra="$(fake_iso ubuntu-22.04.99-live-server-amd64.iso)"
if [[ "$HOST_CN" == "jammy" ]]; then
  iso_outra="$(fake_iso ubuntu-25.10-live-server-amd64.iso)"
  ver_esperada="25.10"
else
  ver_esperada="22.04"
fi
out="$(dry "$iso_outra" --iso-repo auto)"
if grep -q "Ubuntu ${ver_esperada}" <<< "$out"; then
  ok "a versão da base vem do NOME do arquivo (${ver_esperada}), não do default"
else
  bad "a versão da base NÃO veio do nome do arquivo (esperava ${ver_esperada})"
fi
if grep -q "Release incompatível" <<< "$out"; then
  ok "release diferente da máquina → AVISO de incompatibilidade"
else
  bad "release diferente NÃO gerou aviso (embutiria .deb errados em silêncio)"
fi
if grep -q "Seguindo SEM repositório local" <<< "$out"; then
  ok "release diferente → repositório local é descartado (degradação explícita)"
else
  bad "release diferente NÃO descartou o repositório"
fi
if grep -q "sobe SEM SSH" <<< "$out"; then
  ok "o aviso diz a CONSEQUÊNCIA (alvo sem rede sobe sem SSH)"
else
  bad "o aviso não diz a consequência para o SSH"
fi

# --- 2. Release que CASA com a máquina → repo montado --------------------
# O nome é montado a partir do codename do host; a versão sai da tabela.
ver_host=""
case "$HOST_CN" in
  jammy) ver_host="22.04" ;; noble) ver_host="24.04" ;;
  oracular) ver_host="24.10" ;; plucky) ver_host="25.04" ;;
  questing) ver_host="25.10" ;; resolute) ver_host="26.04" ;;
esac

if [[ -n "$ver_host" ]]; then
  iso_ok="$(fake_iso "ubuntu-${ver_host}.9-live-server-amd64.iso")"
  out="$(dry "$iso_ok" --iso-repo auto)"
  if grep -q "Release confere" <<< "$out"; then
    ok "release igual à da máquina → 'Release confere' (${HOST_CN})"
  else
    bad "release igual à da máquina NÃO foi reconhecida (${HOST_CN})"
  fi
  if grep -q "baixaria o fecho de dependências" <<< "$out"; then
    ok "release compatível → o repositório local VAI ser montado"
  else
    bad "release compatível não montou o repositório (a ISO sairia dependente de rede)"
  fi
  if grep -qE 'openssh-server' <<< "$out"; then
    ok "o fecho de dependências inclui o openssh-server (o alvo nasce com SSH)"
  else
    bad "o fecho não inclui o openssh-server"
  fi
else
  echo "  (host '${HOST_CN:-desconhecido}' fora da tabela: pulo o caso de release igual)"
fi

# --- 3. Nome fora do padrão: degrada, não explode ------------------------
iso_estranha="$(fake_iso minha-iso-caseira.iso)"
out="$(dry "$iso_estranha" --iso-repo auto)"
if grep -qE "Não sei o codename|Release incompatível" <<< "$out"; then
  ok "nome fora do padrão → aviso (nunca silêncio)"
else
  bad "nome fora do padrão não gerou aviso"
fi

# --- 4. --iso-repo none nunca monta repositório --------------------------
out="$(dry "$iso_estranha" --iso-repo none)"
if ! grep -q "baixaria o fecho de dependências" <<< "$out"; then
  ok "--iso-repo none não monta repositório (respeita a escolha)"
else
  bad "--iso-repo none montou repositório mesmo assim"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "iso-release: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "iso-release: PASS=${PASS} FAIL=${FAIL}"
exit 1
