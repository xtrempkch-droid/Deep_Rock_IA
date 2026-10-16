#!/usr/bin/env bash
#
# tests/test-ci-guards.sh — prova que os guardas do CI REALMENTE derrubam o job
# -----------------------------------------------------------------------------
# "Guarda que nunca reprovou não é guarda."
#
# Descobri na marra (sessão #19) que SEIS guardas negativos do job
# `project-rules` eram DECORATIVOS: estavam escritos como `! grep -q X arquivo`,
# e o `set -e` do bash **ignora o exit status de um comando invertido com `!`**
# (está na doc do `set`: "...or if the command's return value is being inverted
# with !"). Ou seja, a violação era detectada e... nada acontecia: o job seguia
# verde. Pior: os testes que eu vinha fazendo "reprovavam" por causa do guarda
# POSITIVO que vinha logo depois, dando a impressão de que o negativo funcionava.
#
# Este teste fecha o buraco em dois níveis:
#   1. Roda os passos do job como o CI roda (`bash -e`, um por passo) e exige que
#      o job PASSE numa árvore limpa;
#   2. PLANTA cada violação, uma por vez, e exige que o job FALHE.
#
# Nada é alterado na árvore de trabalho: tudo acontece numa cópia temporária
# (o repositório tem ~1,3 MB, então copiar é barato e elimina o risco de deixar
# o workspace sujo se o teste for interrompido).
#
# Uso: bash tests/test-ci-guards.sh [--verbose]
# Requer: python3 (para extrair os blocos `run:` do workflow). Sem rede, sem root.
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
SRC_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly SRC_ROOT

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly REPO="${WORK}/repo"
readonly PRISTINE="${WORK}/pristine"

# Copia a árvore de trabalho (sem .git) — duas vezes: uma para mexer, outra
# para restaurar arquivo a arquivo sem depender de git.
# Exclui os ARTEFATOS de build (iso/work pode ter GB de cache/downloads):
# sem isto, o teste estoura a cota do /tmp (tmpfs) em máquinas que já geraram
# uma ISO — o guarda em si não tem nada a ver com eles.
copy_tree() {
  local dst="$1"
  mkdir -p "$dst"
  tar -C "$SRC_ROOT" \
      --exclude=.git --exclude=iso/out --exclude=iso/work \
      --exclude='./*.iso' --exclude='./*.gguf' \
      -cf - . | tar -C "$dst" -xf -
}
copy_tree "$REPO"
copy_tree "$PRISTINE"

# ---------------------------------------------------------------------------
# Extrai os blocos `run:` do job project-rules, como o CI os executa.
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/blocks"
python3 - "$REPO/.github/workflows/validate.yml" "${WORK}/blocks" <<'PY'
import pathlib, sys
wf, outdir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = wf.read_text().split("\n")
jobs = [(i, l) for i, l in enumerate(lines)
        if l.startswith("  ") and not l.startswith("    ") and l.rstrip().endswith(":")]
start = next(i for i, l in jobs if l.strip() == "project-rules:")
end = next((i for i, l in jobs if i > start), len(lines))
n = 0
for i in range(start, end):
    if lines[i].strip() == "run: |" and len(lines[i]) - len(lines[i].lstrip()) == 8:
        body = []
        for m in lines[i + 1:]:
            if m.strip() == "":
                body.append("")
                continue
            if not m.startswith("          "):
                break
            body.append(m[10:])
        n += 1
        (outdir / f"step{n}.sh").write_text("\n".join(body) + "\n")
print(n)
PY

BLOCKS=$(find "${WORK}/blocks" -name 'step*.sh' | wc -l)
[[ "$BLOCKS" -ge 1 ]] || { echo "não consegui extrair os passos do job"; exit 1; }

# Roda o job inteiro como o CI: cada passo em um shell próprio. O job falha se
# QUALQUER passo falhar.
job_fails() {
  local b
  for b in "${WORK}"/blocks/step*.sh; do
    if ! ( cd "$REPO" && bash -e "$b" >/dev/null 2>&1 ); then
      return 0
    fi
  done
  return 1
}

restore() { cp -a "${PRISTINE}/$1" "${REPO}/$1"; }

# planta <descrição> <arquivo> <como>
# Espera que o job FALHE; restaura em seguida.
planta() {
  local desc="$1" arq="$2"; shift 2
  if job_fails; then
    bad "job JÁ falhava na árvore limpa antes de '${desc}'"
    restore "$arq"
    return 0
  fi
  "$@"
  if job_fails; then
    ok "reprova: ${desc}"
  else
    bad "NÃO reprova (guarda decorativo?): ${desc}"
  fi
  restore "$arq"
}

app() { printf '\n# isca do teste de guardas\n%s\n' "$1" >> "${REPO}/$2"; }
sed_() { sed -i "$1" "${REPO}/$2"; }

echo "Guardas do CI (job project-rules) — ${BLOCKS} passos extraídos"

# --- Sanidade: a árvore limpa (com as minhas mudanças) tem de passar ---------
if job_fails; then
  bad "o job falha numa árvore LIMPA (existe guarda errado ou o repo está sujo)"
else
  ok "árvore limpa: o job passa"
fi

# --- Guardas negativos (o que `! grep` fingia fazer) ------------------------
planta "--gpu auto em llama-build.sh" llama-build.sh app 'foo --gpu auto' llama-build.sh
planta "download em lote sem fallback (xargs -r -n 25)" iso/build-iso.sh app 'foo | xargs -r -n 25 sh -c bar' iso/build-iso.sh
planta "--prebuilt em build-iso.sh" iso/build-iso.sh app 'foo --prebuilt bar' iso/build-iso.sh
planta "COPY build/bin no Dockerfile" docker/Dockerfile app 'COPY build/bin /usr/local/bin/x' docker/Dockerfile
planta "upload-artifact em @v6" .github/workflows/build-llama.yml sed_ 's|upload-artifact@v7|upload-artifact@v6|' .github/workflows/build-llama.yml
planta "actions/checkout em @v4 (major antigo)" .github/workflows/build-llama.yml sed_ 's|actions/checkout@v7|actions/checkout@v4|' .github/workflows/build-llama.yml

# --- Meta-guarda: a PRÓPRIA forma proibida --------------------------------
planta "meta-guarda: volta um guarda na forma '! cmd'" .github/workflows/validate.yml \
  sed_ "s|^          grep -q 'iso-repo-test' Makefile\$|          ! grep -q isca Makefile|" .github/workflows/validate.yml

# --- Guardas de existência/positivos (o outro lado: apagar o alvo) ---------
planta "tirar iso-repo-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-dry-run-both|' Makefile
planta "tirar iso-select-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-repo-test ci-guards-test iso-dry-run-both|' Makefile
planta "tirar ci-guards-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test iso-dry-run-both|' Makefile
planta "tirar iso-verify-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test ci-guards-test iso-dry-run-both|' Makefile
planta "renomear packages_with_candidate()" iso/build-iso.sh \
  sed_ 's|^packages_with_candidate()|packages_with_candidate_velho()|' iso/build-iso.sh
planta "renomear normalize_iso_name()" iso/build-iso.sh \
  sed_ 's|^normalize_iso_name()|normalize_iso_name_velho()|' iso/build-iso.sh
planta "tirar o marcador '*' da fixture do SHA256SUMS" tests/fixtures/SHA256SUMS.ubuntu-24.04 \
  sed_ 's|\*ubuntu-24.04.5|ubuntu-24.04.5|' tests/fixtures/SHA256SUMS.ubuntu-24.04
planta "o verificador esquecer a preseed (volta o falso positivo)" iso/verify-iso.sh \
  sed_ 's|apt-setup/local0/repository|apt-setup/REMOVIDO|' iso/verify-iso.sh
planta "o pendrive deixar de exigir disco inteiro (TYPE)" iso/write-pendrive.sh \
  sed_ 's|TYPE|TIPO|g' iso/write-pendrive.sh
planta "o pendrive deixar de conferir a assinatura CD001" iso/write-pendrive.sh \
  sed_ 's|CD001|XXXXX|g' iso/write-pendrive.sh
planta "o teste do pendrive esquecer que o alvo e um ARQUIVO" tests/test-write-pendrive.sh \
  sed_ 's|ARQUIVO|ALVO|g' tests/test-write-pendrive.sh
planta "o conferidor de ISO esquecer a assinatura CD001" iso/check-iso.sh \
  sed_ 's|CD001|XXXXX|g' iso/check-iso.sh
planta "tirar iso-check-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-dry-run-both|' Makefile
planta "o artifact da ISO voltar a ser gateado pela Release" .github/workflows/iso.yml \
  sed_ 's|steps.size.outputs.release_too_big|steps.size.outputs.too_big|' .github/workflows/iso.yml

# --- Interface web (fácil de degradar sem ninguém notar) --------------------
planta "tirar ui-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-check-test iso-dry-run-both|' Makefile
planta "a UI passar a usar dependência externa" webui/server.py \
  app 'import fastapi' webui/server.py
planta "a UI passar a exigir pip install" webui/server.py \
  app 'print("rode: pip install flask")' webui/server.py
planta "a página passar a carregar um recurso externo (CDN)" webui/index.html \
  app '<script src="https://cdn.jsdelivr.net/npm/x.js"></script>' webui/index.html
planta "a UI voltar a pedir senha de sudo (pendrive)" webui/server.py \
  app 'sudo -S true' webui/server.py
planta "senha em TEXTO PURO na linha de comando da UI" webui/server.py \
  app 'args += ["--password", pw]' webui/server.py
planta "a UI perder o hash crypt (senha chegaria em claro)" webui/server.py \
  sed_ 's|crypt\.crypt|X|g; s|crypt\.mksalt|X|g' webui/server.py
planta "a UI perder a lista branca de ações" webui/server.py \
  sed_ 's|^ACTIONS = {|OPACO = {|' webui/server.py
planta "a UI perder o validador de disco" webui/server.py \
  sed_ 's|^RE_DISK = |# RE_DISK = |' webui/server.py
planta "a UI deixar de recusar bind fora do localhost" webui/server.py \
  sed_ 's|args.host not in|args.host in|' webui/server.py
planta "a ISO passar a levar o webui/ (Regra 13-b)" iso/build-iso.sh \
  sed_ 's|--exclude=./webui||' iso/build-iso.sh

# --- AVX-512 + trava de instância única do gerador de ISO -------------------
planta "tirar avx512-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test pendrive-test iso-check-test ui-test iso-dry-run-both|' Makefile
planta "tirar iso-lock-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test pendrive-test iso-check-test ui-test iso-dry-run-both|' Makefile

# --- Disco do autoinstall: o modo nº 1 de a automação não acontecer ---------
# `--disk auto` ia LITERAL para o YAML e virava `match: {path: auto}`: nenhum
# disco casa e o Subiquity não instala sozinho, sem erro visível.
planta "--disk auto voltar a ir LITERAL para o YAML (match: {path: auto})" iso/build-iso.sh \
  sed_ 's|if \[\[ "$DISK" == "auto" \|\| "$DISK" == "any" \|\| "$DISK" == "none" \]\]; then|if false; then|' iso/build-iso.sh
planta "o default do CI voltar a /dev/vda (só existe em VM)" .github/workflows/iso.yml \
  sed_ "s#inputs.disk || 'auto'#inputs.disk || '/dev/vda'#" .github/workflows/iso.yml
planta "tirar iso-disk-test do validate" Makefile \
  sed_ 's|^validate: .*$|validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test ci-guards-test iso-lock-test pendrive-test iso-check-test ui-test iso-dry-run-both|' Makefile
planta "renomear acquire_build_lock()" iso/build-iso.sh \
  sed_ 's|^acquire_build_lock()|acquire_build_lock_velho()|' iso/build-iso.sh
planta "renomear download_to()" iso/build-iso.sh \
  sed_ 's|^download_to()|download_to_velho()|' iso/build-iso.sh
# A armadilha do run do v0.2.5: `matrix.exec != 'false'` num `if:` NUNCA dá
# falso (booleano x string) e o passo roda no runner sem a ISA -> SIGILL.
planta "voltar a comparar matrix.exec com STRING num if:" .github/workflows/build-llama.yml \
  app "        if: steps.model.outputs.ok == '1' && matrix.exec != 'false'" .github/workflows/build-llama.yml

# --- Repositório apt: a 2ª tentativa tem de ser diagnosticável --------------
planta "o retry deixar de refrescar o índice (404 de espelho volta)" iso/build-iso.sh \
  sed_ 's|índice fresco para a 2ª tentativa|segunda tentativa|' iso/build-iso.sh
planta "o retry voltar a descartar a saída do apt (log ilegível)" iso/build-iso.sh \
  sed_ 's|apt-get download -o Acquire::Retries=5 "\$p"|apt-get download -o Acquire::Retries=5 ${faltando}|' iso/build-iso.sh

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ci-guards: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "ci-guards: PASS=${PASS} FAIL=${FAIL}"
exit 1
