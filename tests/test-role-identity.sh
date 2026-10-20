#!/usr/bin/env bash
#
# tests/test-role-identity.sh — prova a identidade derivada do PAPEL (ADR-002)
# -----------------------------------------------------------------------------
# Por que este teste existe:
#
#   A máquina tem uma FUNÇÃO — `inference` (servidor de IA) ou `builder`
#   (build + registry + Gitea) — e o nome do usuário é a única coisa que
#   aparece em TODAS as superfícies de operação: prompt, `ssh`, `known_hosts`,
#   logs, `sudoers` e (mais adiante) o nó do `ai-talk`. Um usuário fixo
#   (`ai-cpu-os`) obriga quem chega a descobrir *por fora* onde está.
#
#   O ADR-002 decidiu derivar a identidade do papel JÁ NA GERAÇÃO da ISO,
#   porque renomear usuário depois da instalação mexe em home, `sudoers`,
#   chaves e serviços — e foi rejeitado.
#
# O que este teste cobre (os critérios de aceite, um a um):
#   1. --role inference → ai-inference / ai-inference
#   2. --role builder   → ai-builder / ai-builder
#   3. --role auto      → ai-cpu-os + AVISO de que não houve derivação
#   4. --username custom vence qualquer papel
#   5. --hostname custom vence o padrão
#   6. --role inference --username custom → custom / custom
#   7. o autoinstall.yaml REAL e o .iso-config refletem a identidade
#   8. o --dry-run imprime a identidade (testável sem gerar ISO)
#   9. o verificador APROVA a árvore coerente e REPROVA a incoerente
#
# Sem ISO, sem rede, sem root: tudo por `--dry-run` e `--check-templates`.
#
# Uso: bash tests/test-role-identity.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); if [[ $VERBOSE -eq 1 ]]; then printf '  ok   %s\n' "$*"; fi; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

BUILD="iso/build-iso.sh"
VERIFY="iso/verify-iso.sh"
for f in "$BUILD" "$VERIFY"; do
  [[ -f "$f" ]] || { printf 'FALHOU: %s não existe\n' "$f" >&2; exit 1; }
done

# Nunca em pipe: `grep -q` num pipeline com `set -o pipefail` dá SIGPIPE (uma
# armadilha que já custou três sessões neste projeto).
dry() {
  bash "$BUILD" --dry-run --yes --distro ubuntu "$@" 2>&1 || true
}

# identity_line() é o formato estável que o build imprime; extraímos os campos.
field() {
  local out="$1" key="$2"
  printf '%s\n' "$out" \
    | sed -n 's/.*identidade: usuario=\([^ ]*\) hostname=\([^ ]*\) papel=\([^ ]*\) origem=\([^ ]*\).*/\1 \2 \3 \4/p' \
    | tail -1 \
    | awk -v k="$key" '{print (k=="usuario")?$1:(k=="hostname")?$2:(k=="papel")?$3:$4}'
}

echo "Identidade derivada do papel (ADR-002)"

# ---------------------------------------------------------------------------
# 1) + 8) inference → ai-inference, e a linha do --dry-run existe
# ---------------------------------------------------------------------------
out="$(dry --role inference)"
if printf '%s\n' "$out" | grep -q 'identidade: usuario='; then
  ok "--dry-run imprime a linha de identidade (critério 8)"
else
  bad "--dry-run NÃO imprime a identidade (não dá para testar sem gerar ISO)"
fi

check_id() { # <descrição> <saída> <esperado_usr> <esperado_host> <esperado_origem>
  local desc="$1" out="$2" want_u="$3" want_h="$4" want_o="$5" got_u got_h got_o
  got_u="$(field "$out" usuario)"
  got_h="$(field "$out" hostname)"
  got_o="$(field "$out" origem)"
  if [[ "$got_u" == "$want_u" && "$got_h" == "$want_h" && "$got_o" == "$want_o" ]]; then
    ok "$desc → ${want_u} @ ${want_h} (origem=${want_o})"
  else
    bad "$desc: esperado ${want_u} @ ${want_h} (origem=${want_o}), obtido '${got_u}' @ '${got_h}' (origem=${got_o})"
  fi
}

check_id "--role inference" "$out" "ai-inference" "ai-inference" "papel"

# ---------------------------------------------------------------------------
# 2) builder → ai-builder
# ---------------------------------------------------------------------------
check_id "--role builder" "$(dry --role builder)" "ai-builder" "ai-builder" "papel"

# ---------------------------------------------------------------------------
# 3) auto → ai-cpu-os, SEM derivação, e com aviso explícito (Regra 13-a)
# ---------------------------------------------------------------------------
out_auto="$(dry)"
check_id "--role auto (padrão)" "$out_auto" "ai-cpu-os" "ai-cpu-os" "padrao-auto"
case "$out_auto" in
  *"identidade NÃO é derivada"*)
    ok "papel auto: avisa que a identidade NÃO é derivada (não mente por omissão)" ;;
  *"NÃO é derivada"*)
    ok "papel auto: avisa que a identidade NÃO é derivada" ;;
  *) bad "papel auto: não avisa que a identidade deixa de ser derivada" ;;
esac
case "$out_auto" in
  *"--role inference ou --role builder"*)
    ok "o aviso diz COMO obter identidade por função (dá o próximo passo)" ;;
  *) bad "o aviso do papel auto não diz o que fazer" ;;
esac

# ---------------------------------------------------------------------------
# 4) --username custom vence qualquer papel
# ---------------------------------------------------------------------------
check_id "--role inference --username custom" \
  "$(dry --role inference --username custom)" "custom" "custom" "explicito"
check_id "--role builder --username outro" \
  "$(dry --role builder --username outro)" "outro" "outro" "explicito"

# ---------------------------------------------------------------------------
# 5) --hostname explícito vence o padrão (frota do mesmo papel, ADR-002 §5)
# ---------------------------------------------------------------------------
check_id "--role inference --hostname ai-inference-2" \
  "$(dry --role inference --hostname ai-inference-2)" "ai-inference" "ai-inference-2" "papel"
check_id "--role builder --hostname ai-builder-3" \
  "$(dry --role builder --hostname ai-builder-3)" "ai-builder" "ai-builder-3" "papel"

# ---------------------------------------------------------------------------
# 6) + 7) A árvore REAL: autoinstall.yaml e .iso-config refletem a identidade
# ---------------------------------------------------------------------------
# `--keep-templates` deixa a árvore em disco; é a única forma de conferir o
# YAML gerado e o `.iso-config` sem gerar uma ISO de 5 GB.
tpl_out="$(bash "$BUILD" --check-templates --keep-templates --role inference --yes 2>&1 || true)"
tpl_dir="$(printf '%s\n' "$tpl_out" | sed -n 's/.*TEMPLATES_DIR=//p' | tail -1)"

if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
  ok "--keep-templates devolveu a árvore com --role inference"
  ai_yaml="$(find "$tpl_dir" -name autoinstall.yaml -type f | head -1)"
  lc_sh="$(find "$tpl_dir" -name late-command.sh -type f | head -1)"

  if [[ -n "$ai_yaml" ]]; then
    if grep -qE '^[[:space:]]*username:[[:space:]]*"ai-inference"$' "$ai_yaml"; then
      ok "autoinstall.yaml: identity.username = ai-inference (critério 1)"
    else
      bad "autoinstall.yaml não tem identity.username = ai-inference"
    fi
    if grep -qE '^[[:space:]]*hostname:[[:space:]]*"ai-inference"$' "$ai_yaml"; then
      ok "autoinstall.yaml: identity.hostname = ai-inference"
    else
      bad "autoinstall.yaml não tem identity.hostname = ai-inference"
    fi
    # O GECOS diz a FUNÇÃO: quem roda `getent passwd` no alvo vê o papel.
    if grep -qE '^[[:space:]]*realname:[[:space:]]*"ai-inference \(inference\)"$' "$ai_yaml"; then
      ok "autoinstall.yaml: GECOS declara a função ('ai-inference (inference)')"
    else
      bad "autoinstall.yaml não declara a função no realname"
    fi
  else
    bad "autoinstall.yaml não encontrado na árvore de teste"
  fi

  # O `.iso-config` do ALVO é escrito pelo late-command: aqui conferimos o
  # TEMPLATE (já substituído), que é o que vai para a mídia.
  if [[ -n "$lc_sh" ]]; then
    if grep -qF 'ISO_USERNAME=%s' "$lc_sh"; then
      ok "late-command.sh grava ISO_USERNAME no .iso-config do alvo"
    else
      bad "late-command.sh não grava ISO_USERNAME (a identidade não chega ao alvo)"
    fi
    if grep -qF "'ai-inference'" "$lc_sh"; then
      ok "late-command.sh carrega o usuário resolvido ('ai-inference')"
    else
      bad "late-command.sh não carrega o usuário resolvido"
    fi
    if grep -qF "'papel'" "$lc_sh"; then
      ok "late-command.sh grava a ORIGEM da identidade ('papel')"
    else
      bad "late-command.sh não grava a origem da identidade"
    fi
  else
    bad "late-command.sh não encontrado na árvore de teste"
  fi

  # ---------------------------------------------------------------------------
  # 9) O verificador: a árvore COMPLETA (com o projeto) passa no selftest, e a
  #    seção de identidade dele aprova/ reprova nos casos certos.
  # ---------------------------------------------------------------------------
  # O `--check-templates` roda o `verify-iso.sh` sobre uma árvore completa de
  # mentira (projeto real + templates reais + grub). Exit 0 significa: o
  # verificador aprovou TUDO, inclusive a seção "Identidade (ADR-002)".
  if bash "$BUILD" --check-templates --role inference --yes >/dev/null 2>&1; then
    ok "verify-iso.sh APROVA a árvore completa com --role inference (critério 9)"
  else
    bad "verify-iso.sh reprovou a árvore completa com --role inference"
  fi

  # Agora o teste ESTREITO da seção de identidade: uma árvore com só os dois
  # arquivos que ela lê. O verificador reprova o resto (e não importa), mas as
  # linhas da identidade ficam isoladas — é o que queremos julgar.
  # Um verificador que nunca falha não vale nada.
  id_tree="${tmp}/id-tree"
  mkdir -p "${id_tree}/ai-cpu-os-boot"
  cp "$ai_yaml" "${id_tree}/autoinstall.yaml"
  cp "$lc_sh" "${id_tree}/ai-cpu-os-boot/late-command.sh"

  id_out="$(bash "$VERIFY" --dir "$id_tree" --distro ubuntu --role inference 2>&1 || true)"
  case "$id_out" in
    *"PASS] papel inference → usuário ai-inference"*)
      ok "verify-iso.sh confere a DERIVAÇÃO do papel (não só a presença do campo)" ;;
    *) bad "verify-iso.sh não confere a derivação do papel" ;;
  esac

  # Planta a incoerência: o instalador criaria um usuário e o papel diria outro.
  # É o modo de falha silencioso que este teste existe para pegar.
  sed -i 's/^\([[:space:]]*username:[[:space:]]*\)"ai-inference"$/\1"outro-usuario"/' \
    "${id_tree}/autoinstall.yaml"
  id_bad="$(bash "$VERIFY" --dir "$id_tree" --distro ubuntu --role inference 2>&1 || true)"
  case "$id_bad" in
    *"FAIL] papel inference →"*|*"FAIL] papel inference deveria dar usuário"*)
      ok "verify-iso.sh REPROVA usuário incoerente com o papel" ;;
    *"FAIL]*identidade coerente"*)
      ok "verify-iso.sh REPROVA a divergência autoinstall x late-command" ;;
    *) bad "verify-iso.sh APROVOU usuário incoerente com o papel (não pega a regressão)" ;;
  esac

  rm -rf "$tpl_dir"
else
  bad "--keep-templates não devolveu TEMPLATES_DIR (recebi '${tpl_dir}')"
fi

# ---------------------------------------------------------------------------
# Extra: `--username` vence também no YAML real, e o verificador aceita
# ---------------------------------------------------------------------------
# O verificador não pode ser rígido demais: `--username` explícito é legítimo
# (frota, imagem padronizada), então o papel concreto NÃO obriga o nome.
tpl_out="$(bash "$BUILD" --check-templates --keep-templates --role builder --username adm --yes 2>&1 || true)"
tpl_dir="$(printf '%s\n' "$tpl_out" | sed -n 's/.*TEMPLATES_DIR=//p' | tail -1)"
if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
  ai_yaml="$(find "$tpl_dir" -name autoinstall.yaml -type f | head -1)"
  if [[ -n "$ai_yaml" ]] && grep -qE '^[[:space:]]*username:[[:space:]]*"adm"$' "$ai_yaml"; then
    ok "papel builder + --username adm: o usuário explícito vence no YAML (critério 4)"
  else
    bad "--username adm não venceu o papel builder no YAML gerado"
  fi
  if bash "$BUILD" --check-templates --role builder --username adm --yes >/dev/null 2>&1; then
    ok "verify-iso.sh aceita --username explícito com papel concreto (não é rígido demais)"
  else
    bad "verify-iso.sh reprovou um --username explícito legítimo"
  fi
  rm -rf "$tpl_dir"
else
  bad "árvore com --username não foi gerada"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "role-identity: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "role-identity: PASS=${PASS} FAIL=${FAIL}"
exit 1
