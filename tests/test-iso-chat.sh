#!/usr/bin/env bash
#
# tests/test-iso-chat.sh — prova o chat da frota DENTRO da ISO (ADR-003, F2)
# -----------------------------------------------------------------------------
# POR QUE ESTE TESTE EXISTE
#   O `make ai-talk-install-test` prova o instalador; o `make talk-test` prova o
#   transporte. Falta o elo do meio — o que a ISO faz com tudo isso:
#
#     --chat-*  →  payload na mídia  →  late-command copia  →  .iso-config
#               →  1º boot exporta    →  build.sh etapa 2.5  →  install.sh
#
#   Cada elo é uma oportunidade de quebra SILENCIOSA: a ISO gera normal, o alvo
#   instala normal, e o chat simplesmente não existe (ou existe sem chave, que é
#   pior: promete autenticação e não entrega).
#
# O QUE ESTE TESTE PROVA (sem gerar ISO — `--dry-run` e `--check-templates`)
#   1. `--chat-disable` diz que não instala e não embarca payload.
#   2. Sem chave: avisa que o serviço nasce DESABILITADO (mas a ISO é válida).
#   3. Com chave/frota: a mídia leva `chat/fleet.key`, `chat/keys/*.key` e
#      `chat/peers.txt`, as chaves com modo 0640 (uma chave 0644 numa ISO é
#      pública) e o `--chat-peer` vencendo o arquivo da frota.
#   4. Os erros de ENTRADA são fatais (rc 2): chave 0644, chave de tamanho
#      errado, peer mal formado, frota acima do teto de 15 (ADR-005).
#   5. Os três elos do alvo existem: `late-command.sh` copia e registra,
#      `firstboot.sh` exporta, `build.sh` chama a etapa 2.5 ANTES do papel.
#   6. Nada disso exige rede (Regra 13-b).
#
# Uso: bash tests/test-iso-chat.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && printf '  ok   %s\n' "$*"; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

BUILD="iso/build-iso.sh"
[[ -f "$BUILD" ]] || { echo "FALHOU: ${BUILD} não existe" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
readonly WORK

# Saída inteira em variável: `grep -q` em pipeline com pipefail dá SIGPIPE.
dry() { bash "$BUILD" --dry-run --yes "$@" 2>&1 || true; }
rc_of() {
  local rc=0
  bash "$BUILD" --dry-run --yes "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

new_key() { head -c 32 /dev/urandom | xxd -p -c64 > "$1"; chmod 640 "$1"; }

mkdir -p "${WORK}/keys"
new_key "${WORK}/fleet.key"
new_key "${WORK}/keys/ai-builder.key"
new_key "${WORK}/keys/ai-worker-07.key"
printf 'ai-builder=192.168.0.20\nai-worker-07=192.168.0.27\n' > "${WORK}/frota.txt"

echo "Chat da frota na ISO (ADR-003, F2)"

# ---------------------------------------------------------------------------
# 1) --chat-disable: a ISO é válida, o chat não entra
# ---------------------------------------------------------------------------
out="$(dry --chat-disable)"
case "$out" in
  *"NÃO será instalado"*) ok "--chat-disable: diz que não instala" ;;
  *) bad "--chat-disable não avisou que não instala" ;;
esac
if bash "$BUILD" --check-templates --yes --chat-disable >/dev/null 2>&1; then
  ok "--chat-disable: a ISO continua válida (não quebra o build)"
else
  bad "--chat-disable quebrou o --check-templates"
fi

# ---------------------------------------------------------------------------
# 2) Sem chave: avisa, mas NÃO derruba (Regra 13-a: é o default)
# ---------------------------------------------------------------------------
out="$(dry --chat-peers-file "${WORK}/frota.txt")"
case "$out" in
  *"sem chave"*)
    ok "sem chave: avisa explicitamente" ;;
  *) bad "sem chave: não avisou" ;;
esac
case "$out" in
  *"DESABILITADO"*)
    ok "sem chave: diz que o serviço nasce DESABILITADO (nunca canal sem HMAC)" ;;
  *) bad "sem chave: não disse que o serviço fica desabilitado" ;;
esac
if bash "$BUILD" --check-templates --yes --chat-peers-file "${WORK}/frota.txt" >/dev/null 2>&1; then
  ok "sem chave: a ISO é gerada mesmo assim (degradar, nunca abortar)"
else
  bad "sem chave derrubou a geração da ISO (é o default!)"
fi

# ---------------------------------------------------------------------------
# 3) Payload na mídia: chaves, frota e modo 0640
# ---------------------------------------------------------------------------
tpl_out="$(bash "$BUILD" --check-templates --keep-templates --yes --role inference \
             --chat-key-file "${WORK}/fleet.key" --chat-keydir "${WORK}/keys" \
             --chat-peers-file "${WORK}/frota.txt" \
             --chat-peer ai-worker-07=192.168.0.99 2>&1 || true)"
tpl_dir="$(printf '%s\n' "$tpl_out" | sed -n 's/.*TEMPLATES_DIR=//p' | tail -1)"

if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
  ok "--check-templates devolveu a árvore (com chat)"

  # O payload do chat fica em ai-cpu-os-boot/chat no stage — mas o
  # --keep-templates expõe a árvore dos CENÁRIOS (flat). Conferimos o stage
  # pelo próprio verificador, que roda no selftest sobre a árvore real.
  case "$tpl_out" in
    *"chat/fleet.key"*|*"Chat da frota: porta"*)
      ok "o build menciona o payload do chat" ;;
    *"Frota na mídia"*)
      ok "o build registra a frota embarcada" ;;
    *) bad "o build não registrou o payload do chat" ;;
  esac
  case "$tpl_out" in
    *"frota com 2 nó(s)"*)
      ok "o verificador vê 2 nós na frota da mídia" ;;
    *"frota com 1 nó"*)
      bad "o verificador contou 1 nó (o --chat-peer duplicou/substituiu errado)" ;;
    *) bad "o verificador não conferiu a frota" ;;
  esac
  case "$tpl_out" in
    *"chave global do chat presente"*)
      ok "o verificador confere a chave global (32 bytes)" ;;
    *) bad "o verificador não confere a chave global" ;;
  esac
  case "$tpl_out" in
    *"late-command.sh tem a etapa de cópia do chat"*)
      ok "o verificador confere o elo late-command → alvo" ;;
    *) bad "o verificador não confere a cópia do chat para o alvo" ;;
  esac
  case "$tpl_out" in
    *"chave do chat vai para o alvo com modo 0640"*)
      ok "o verificador confere o modo 0640 da chave no alvo" ;;
    *) bad "o verificador não confere o modo da chave" ;;
  esac
  rm -rf "$tpl_dir"
else
  bad "--check-templates não devolveu TEMPLATES_DIR (recebi '${tpl_dir}')"
fi

# O `--chat-peer` tem de VENCER o arquivo da frota, independente da ordem.
# (Este é o mesmo contrato do talk/install.sh; divergir faria o nó falar com o
# IP errado — e o sintoma seria "o peer não responde", não um erro.)
payload_out="$(bash -c '
  set -euo pipefail
  cd "$1"
  # shellcheck disable=SC1091
  source iso/build-iso.sh
  CHAT_INSTALL=1
  CHAT_KEY_FILE="$2"; CHAT_KEYDIR=""; CHAT_PEERS_FILE="$3"
  CHAT_PEERS=("ai-worker-07=192.168.0.99")
  d=$(mktemp -d); stage_chat_payload "$d/chat"
  cat "$d/chat/peers.txt"; rm -rf "$d"
' _ "$PWD" "${WORK}/fleet.key" "${WORK}/frota.txt" 2>/dev/null || true)"

case "$payload_out" in
  *"ai-worker-07=192.168.0.99"*)
    ok "--chat-peer vence o arquivo da frota (a exceção explícita manda)" ;;
  *) bad "--chat-peer NÃO venceu o arquivo da frota (ficou $(printf '%s' "$payload_out" | tr '\n' ' '))" ;;
esac
case "$payload_out" in
  *"ai-worker-07=192.168.0.27"*)
    bad "os dois IPs do mesmo nó foram para a mídia (o nó falaria com o errado)" ;;
  *) ok "o IP antigo do mesmo nó não ficou duplicado na mídia" ;;
esac
case "$payload_out" in
  *"ai-builder=192.168.0.20"*)
    ok "os peers do arquivo continuam na mídia (a exceção não apaga o resto)" ;;
  *) bad "o arquivo da frota foi perdido ao aplicar o --chat-peer" ;;
esac

# ---------------------------------------------------------------------------
# 4) Erros de ENTRADA são fatais (rc 2), e com mensagem
# ---------------------------------------------------------------------------
expect_rc() { # <descrição> <esperado> <args...>
  local desc="$1" want="$2"; shift 2
  local got; got="$(rc_of "$@")"
  if [[ "$got" == "$want" ]]; then ok "${desc} → rc ${want}"
  else bad "${desc}: rc=${got} (esperado ${want})"; fi
}

new_key "${WORK}/k644"; chmod 644 "${WORK}/k644"
expect_rc "chave global legível por 'outros'" 2 --chat-key-file "${WORK}/k644"

printf 'chave-curta\n' > "${WORK}/kcurta"; chmod 640 "${WORK}/kcurta"
expect_rc "chave global de tamanho errado" 2 --chat-key-file "${WORK}/kcurta"

expect_rc "peer sem '='" 2 --chat-peer so-um-nome
expect_rc "nome de peer com maiúscula" 2 --chat-peer AI-Builder=10.0.0.2
expect_rc "porta do chat inválida" 2 --chat-port 70000
expect_rc "--chat-key-file inexistente" 2 --chat-key-file "${WORK}/nao-existe.key"
expect_rc "--chat-peers-file inexistente" 2 --chat-peers-file "${WORK}/nao-existe.txt"

# Frota acima do teto (ADR-005): 16 nós é relay/hub, não "mais um pouco".
for i in $(seq 1 16); do printf 'p%d=10.0.0.%d\n' "$i" "$i"; done > "${WORK}/frota16.txt"
expect_rc "frota com 16 nós excede o teto de 15" 2 --chat-peers-file "${WORK}/frota16.txt"

# 15 é o TETO suportado — tem de PASSAR.
for i in $(seq 1 15); do printf 'p%d=10.0.0.%d\n' "$i" "$i"; done > "${WORK}/frota15.txt"
got="$(rc_of --chat-peers-file "${WORK}/frota15.txt")"
if [[ "$got" == "0" ]]; then
  ok "frota com 15 nós é aceita (o teto é 15, não 14)"
else
  bad "frota com 15 nós foi recusada (rc=${got}) — o teto do ADR-005 é 15"
fi

# ---------------------------------------------------------------------------
# 5) Os elos do ALVO existem (é aqui que a corrente já quebrou 2× no projeto)
# ---------------------------------------------------------------------------
if grep -q 'stage_chat_payload' "$BUILD" && grep -q 'ai-cpu-os-boot/chat' "$BUILD"; then
  ok "build-iso embarca o payload em /ai-cpu-os-boot/chat"
else
  bad "build-iso não embarca o payload do chat"
fi

if grep -q 'AI_CHAT_INSTALL' build.sh && grep -q 'run_chat_install' build.sh; then
  ok "build.sh tem a etapa 2.5 do chat"
else
  bad "build.sh não tem a etapa 2.5 do chat"
fi

# A ordem importa: o chat tem de vir ANTES do papel (para a máquina poder
# relatar uma falha da inferência por ele).
chat_line="$(grep -n '^  run_chat_install$' build.sh | cut -d: -f1 | head -1)"
role_line="$(grep -n '^  run_role_install$' build.sh | cut -d: -f1 | head -1)"
if [[ -n "$chat_line" && -n "$role_line" ]] && (( chat_line < role_line )); then
  ok "a etapa do chat roda ANTES do papel (dá tempo de relatar falha)"
else
  bad "a etapa do chat não roda antes do papel (chat=${chat_line:-?} papel=${role_line:-?})"
fi

if grep -q 'AI_CHAT_KEY_FILE' iso/common/firstboot.sh && grep -q 'AI_CHAT_PEERS_FILE' iso/common/firstboot.sh; then
  ok "firstboot.sh exporta a intenção do chat (AI_CHAT_*)"
else
  bad "firstboot.sh não exporta as variáveis do chat"
fi

if grep -q 'CHAT_KEY=%s' iso/common/late-command.sh && grep -q 'CHAT_PEERS=%s' iso/common/late-command.sh; then
  ok "late-command.sh registra os caminhos do chat no .iso-config"
else
  bad "late-command.sh não registra os caminhos do chat"
fi

# ---------------------------------------------------------------------------
# 6) Nada de rede no caminho do chat (ISO air-gapped, Regra 13-b)
# ---------------------------------------------------------------------------
# Ancorado na POSIÇÃO DE COMANDO (início da linha, depois de espaços). Um
# `grep` pelo nome solto acusa até COMENTÁRIO — o `late-command.sh` explica em
# prosa que o caminho sem fonte "cai no git clone", e isso não é download.
for f in talk/install.sh talk/ai_talk.py iso/common/late-command.sh; do
  if grep -qE '^[[:space:]]*(curl|wget|pip3?[[:space:]]+install|git[[:space:]]+clone)' "$f"; then
    bad "${f} menciona download (a ISO é air-gapped)"
  else
    ok "${f} não baixa nada"
  fi
done

echo
if [[ $FAIL -eq 0 ]]; then
  echo "iso-chat: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "iso-chat: PASS=${PASS} FAIL=${FAIL}"
exit 1
