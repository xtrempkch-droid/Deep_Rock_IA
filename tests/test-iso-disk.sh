#!/usr/bin/env bash
#
# tests/test-iso-disk.sh — prova o tratamento do DISCO do autoinstall
# -----------------------------------------------------------------------------
# Por que este teste existe (bug real, encontrado em 2026-10-16):
#
#   O modo nº 1 de a instalação automática NÃO acontecer é o autoinstall fixar
#   um disco que não existe no alvo. O `storage` vira
#   `layout: {name: direct, match: {path: /dev/vda}}`; se o alvo não tiver
#   exatamente esse caminho, NENHUM disco casa, o Subiquity não instala sozinho
#   e **não há erro visível** — a máquina fica parada na tela do instalador.
#
#   A documentação recomendava `--disk auto` como mitigação... e `--disk auto`
#   NÃO funcionava: o valor era usado literalmente e gerava
#   `match: {path: auto}` — um caminho inventado, que também não casa com disco
#   nenhum. Ou seja: a mitigação documentada reproduzia o próprio bug.
#
# O que este teste cobre:
#   1. Semântica do YAML gerado (via --keep-templates): com --disk, o layout
#      FIXA o caminho; sem --disk, o layout NÃO restringe nada.
#   2. `--disk auto` (e any/none) → "não fixa o disco" de verdade.
#   3. Disco em formato inválido → erro de uso (rc 2), não ISO quebrada.
#   4. Disco que não existe nesta máquina → AVISO explícito (não erro: gerar
#      para OUTRA máquina é legítimo, mas o log precisa dizer).
#   5. Sem --disk e sem consentimento → rc 2 (não gerar ISO que apaga o que vier).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); if [[ $VERBOSE -eq 1 ]]; then printf '  ok   %s\n' "$*"; fi; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

BUILD="iso/build-iso.sh"
[[ -f "$BUILD" ]] || { echo "FALHOU: $BUILD não existe" >&2; exit 1; }

# Roda o gerador em --dry-run e devolve a saída inteira (sem pipe: o `grep -q`
# num pipeline com `set -o pipefail` dá SIGPIPE — armadilha já pisada 3×).
dry() {
  bash "$BUILD" --dry-run --yes --distro ubuntu "$@" 2>&1 || true
}

# ---------------------------------------------------------------------------
# 1) O YAML gerado: com --disk fixa o caminho; sem --disk não restringe
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

out_tpl="$(bash "$BUILD" --check-templates --keep-templates --yes 2>&1 || true)"
tpl_dir="$(printf '%s\n' "$out_tpl" | sed -n 's/.*TEMPLATES_DIR=//p' | tail -1)"

if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
  ok "--keep-templates devolveu a árvore (TEMPLATES_DIR=…)"
else
  bad "--keep-templates não devolveu TEMPLATES_DIR (recebi '${tpl_dir}')"
fi

if [[ -n "$tpl_dir" && -d "$tpl_dir" ]]; then
  com="${tpl_dir}/com-disco/autoinstall.yaml"
  sem="${tpl_dir}/sem-disco/autoinstall.yaml"

  # (a) com disco: o layout TEM de fixar o caminho pedido.
  if grep -q 'match: {path: /dev/nvme0n1}' "$com" 2>/dev/null; then
    ok "com --disk: o layout fixa match.path (/dev/nvme0n1)"
  else
    bad "com --disk o layout não fixou o disco (o alvo podia ser outro!)"
  fi

  # (b) sem disco: o layout NÃO pode restringir caminho nenhum.
  if grep -q 'layout: {name: direct}' "$sem" 2>/dev/null; then
    ok "sem --disk: layout = {name: direct} (sem restrição de disco)"
  else
    bad "sem --disk o layout não é o esperado"
  fi
  # Ancorado no bloco `storage:` — o autoinstall também tem `match:` no bloco
  # `network:` (interface por glob), que NÃO tem nada a ver com disco. Um
  # `grep 'match:'` no arquivo inteiro dava falso positivo desde que a rede
  # passou a ser emitida (sessão #33).
  storage_block="$(awk '/^storage:/{f=1} f{print} /^# ---/{if(f)exit}' "$sem")"
  if grep -q 'match:' <<<"$storage_block"; then
    bad "sem --disk o layout ainda restringe disco (o instalador não acharia nenhum)"
  else
    ok "sem --disk: NENHUM match no layout (não trava em disco inexistente)"
  fi

  # (c) O BUG: `match: {path: auto}` é um caminho inventado. Nunca pode existir.
  if grep -rq 'match: {path: auto}\|match: {path: any}\|match: {path: none}' "$tpl_dir" 2>/dev/null; then
    bad "apareceu match: {path: auto} — a mitigação documentada está quebrada de novo"
  else
    ok "nenhum 'match: {path: auto}' (o valor literal não vaza para o YAML)"
  fi
  rm -rf "$tpl_dir"
fi

# ---------------------------------------------------------------------------
# 2) `--disk auto|any|none` → não fixa o disco (a mitigação documentada)
# ---------------------------------------------------------------------------
for v in auto any none; do
  out="$(dry --disk "$v")"
  case "$out" in
    *"disco: <não fixado>"*)
      ok "--disk ${v}: tratado como 'não fixar o disco'" ;;
    *"disco: ${v}"*)
      bad "--disk ${v}: foi usado LITERALMENTE (viraria match: {path: ${v}})" ;;
    *)
      bad "--disk ${v}: saída inesperada" ;;
  esac
done

# ---------------------------------------------------------------------------
# 3) Disco em formato inválido → rc 2 (erro de uso, não ISO quebrada)
# ---------------------------------------------------------------------------
for mau in "/dev/../etc" "sda" "/etc/passwd" "dev/sda"; do
  set +e
  bash "$BUILD" --dry-run --yes --distro ubuntu --disk "$mau" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ $rc -eq 2 ]]; then
    ok "--disk '${mau}': recusado como erro de uso (rc 2)"
  else
    bad "--disk '${mau}': rc=${rc} (esperado 2: não é um dispositivo de bloco)"
  fi
done

# ---------------------------------------------------------------------------
# 4) Disco que não existe nesta máquina → AVISO explícito
# ---------------------------------------------------------------------------
out="$(dry --disk /dev/naoexiste0n1)"
case "$out" in
  *"NÃO existe nesta máquina"*)
    ok "disco inexistente: avisa que ele não existe aqui" ;;
  *) bad "disco inexistente: NÃO avisou (o usuário descobriria na instalação)" ;;
esac
case "$out" in
  *"--disk auto"*)
    ok "o aviso recomenda --disk auto (dá o próximo passo, não só o sintoma)" ;;
  *) bad "o aviso não diz o que fazer" ;;
esac

# ---------------------------------------------------------------------------
# 5) Sem --disk e sem consentimento → rc 2 (não gera ISO que apaga o que vier)
# ---------------------------------------------------------------------------
set +e
bash "$BUILD" --distro ubuntu --yes >/dev/null 2>&1
rc=$?
set -e
if [[ $rc -eq 2 ]]; then
  ok "sem --disk (e sem --allow-any-disk): exige o disco (rc 2)"
else
  bad "sem --disk: rc=${rc} (esperado 2 — não pode gerar ISO que apaga o que vier)"
fi

# Com --allow-any-disk é consentido (em dry-run; o real exigiria xorriso).
out="$(dry --allow-any-disk)"
case "$out" in
  *"disco: <não fixado>"*)
    ok "--allow-any-disk: consentido e o disco não é fixado" ;;
  *) bad "--allow-any-disk não foi aceito como esperado" ;;
esac

echo
if [[ $FAIL -eq 0 ]]; then
  echo "iso-disk: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "iso-disk: PASS=${PASS} FAIL=${FAIL}"
exit 1
