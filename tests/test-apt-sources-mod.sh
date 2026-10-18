#!/usr/bin/env bash
#
# tests/test-apt-sources-mod.sh — prova a mod `apt-sources` SEM root e SEM rede
# -----------------------------------------------------------------------------
# A mod existe para consertar o apt de uma máquina que ficou com fontes
# apontando para o NADA (o caso real: `file:///opt/apt-repo` gravado pela ISO
# antiga sem que o repositório existisse no alvo). Um erro aqui tem o pior modo
# de falha: deixar a máquina sem conseguir instalar nada. Por isso tudo é
# exercitado sobre ÁRVORES FALSAS (`--root`), nunca no sistema real.
#
# O que é provado:
#   1. `file://` cujo caminho NÃO existe é removido (o caso real);
#   2. `file://` cujo caminho EXISTE é preservado (não quebramos repo bom);
#   3. `cdrom:` é removido;
#   4. `.sources` (deb822) sem `URIs:` é removido;
#   5. `.sources` com `file://` inexistente é removido;
#   6. sobra uma fonte HTTP boa → ela é PRESERVADA e não se grava lista nova;
#   7. não sobra fonte utilizável → grava a lista OFICIAL certa por distro
#      (ubuntu → archive.ubuntu.com; debian → deb.debian.org);
#   8. `--dry-run` NÃO altera nenhum arquivo;
#   9. `revert` restaura o estado anterior (inclui o arquivo problemático);
#  10. cada arquivo alterado ganha `.ai-cpu-os.bak`.
#
# Requer: bash, sed, awk, grep. Sem root, sem rede, sem apt.
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly APPLY="${REPO_ROOT}/mods/apt-sources/apply.sh"
readonly REVERT="${REPO_ROOT}/mods/apt-sources/revert.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# Árvore falsa: um "sistema" Debian/Ubuntu com as fontes que quisermos.
mk_root() {
  local d="$1" id="${2:-ubuntu}" codename="${3:-noble}"
  rm -rf "$d"
  mkdir -p "$d/etc/apt/sources.list.d"
  : > "$d/etc/apt/sources.list"
  printf 'ID=%s\nVERSION_CODENAME=%s\n' "$id" "$codename" > "$d/etc/os-release"
}

# `apt-get` é substituído por um stub: o teste não pode tocar em apt de verdade.
# O stub devolve 0 (sucesso) e registra que foi chamado.
mk_apt_stub() {
  local d="$1" rc="${2:-0}"
  mkdir -p "$d/usr/local/bin"
  cat > "$d/usr/local/bin/apt-get" <<EOF
#!/bin/sh
echo "apt-get \$*" >> "${WORK}/apt-called"
exit ${rc}
EOF
  chmod +x "$d/usr/local/bin/apt-get"
}

echo "mod apt-sources (prova sem root, sem rede)"

# --- 1. O CASO REAL: file:// para um caminho que não existe ---------------
d="${WORK}/r1"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'deb [trusted=yes] file:///opt/apt-repo ./\n' > "$d/etc/apt/sources.list.d/ai-cpu-os-local.list"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$d/etc/apt/sources.list"
if bash "$APPLY" --root "$d" >/dev/null 2>&1; then ok "aplica sobre a árvore 1"; else bad "aplica sobre a árvore 1 (rc≠0)"; fi
if [[ ! -f "$d/etc/apt/sources.list.d/ai-cpu-os-local.list" ]]; then
  ok "fontes 'file://' inexistente é REMOVIDA (o caso real)"
else
  bad "fontes 'file://' inexistente NÃO foi removida"
fi
if [[ -f "$d/etc/apt/sources.list.d/ai-cpu-os-local.list.ai-cpu-os.bak" ]]; then
  ok "backup .ai-cpu-os.bak criado antes de alterar"
else
  bad "faltou o backup .ai-cpu-os.bak"
fi
if grep -q 'archive.ubuntu.com' "$d/etc/apt/sources.list"; then
  ok "fonte HTTP boa é PRESERVADA"
else
  bad "fonte HTTP boa foi perdida"
fi

# --- 2. file:// para um caminho que EXISTE: não pode ser tocado ----------
d="${WORK}/r2"; mk_root "$d" debian trixie; mk_apt_stub "$d"
mkdir -p "$d/opt/apt-repo"
printf 'deb [trusted=yes] file:///opt/apt-repo ./\n' > "$d/etc/apt/sources.list.d/local.list"
printf 'deb http://deb.debian.org/debian trixie main\n' > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if [[ -f "$d/etc/apt/sources.list.d/local.list" ]]; then
  ok "repositório local QUE EXISTE é preservado"
else
  bad "repositório local que existia foi removido (quebraria a ISO air-gapped)"
fi

# --- 3. cdrom: ------------------------------------------------------------
d="${WORK}/r3"; mk_root "$d" debian trixie; mk_apt_stub "$d"
printf 'deb cdrom:[Debian GNU/Linux 13.7.0 _Trixie_ - Official amd64 NETINST]/\n' > "$d/etc/apt/sources.list"
printf 'deb http://deb.debian.org/debian trixie main\n' >> "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if ! grep -q 'cdrom:' "$d/etc/apt/sources.list"; then
  ok "fonte 'cdrom:' é removida"
else
  bad "fonte 'cdrom:' continua lá (o apt falha em todo update)"
fi
if grep -q 'deb.debian.org' "$d/etc/apt/sources.list"; then
  ok "o espelho oficial sobrevive à limpeza do cdrom:"
else
  bad "o espelho oficial foi removido junto"
fi

# --- 4. .sources (deb822) sem URIs ---------------------------------------
d="${WORK}/r4"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'Types: deb\nSuites: noble\nComponents: main\n' > "$d/etc/apt/sources.list.d/quebrado.sources"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if [[ ! -f "$d/etc/apt/sources.list.d/quebrado.sources" ]]; then
  ok ".sources SEM 'URIs:' é removido"
else
  bad ".sources sem 'URIs:' sobreviveu"
fi

# --- 5. .sources com file:// inexistente ---------------------------------
d="${WORK}/r5"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'Types: deb\nURIs: file:///opt/nao-existe\nSuites: ./\nComponents: ./\n' > "$d/etc/apt/sources.list.d/x.sources"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if [[ ! -f "$d/etc/apt/sources.list.d/x.sources" ]]; then
  ok ".sources com 'file://' inexistente é removido"
else
  bad ".sources com 'file://' inexistente sobreviveu"
fi

# --- 6. --dry-run não altera NADA ---------------------------------------
d="${WORK}/r6"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'deb [trusted=yes] file:///opt/apt-repo ./\n' > "$d/etc/apt/sources.list.d/ai-cpu-os-local.list"
before="$(md5sum "$d/etc/apt/sources.list.d/ai-cpu-os-local.list" | awk '{print $1}')"
bash "$APPLY" --root "$d" --dry-run >/dev/null 2>&1 || true
after="$(md5sum "$d/etc/apt/sources.list.d/ai-cpu-os-local.list" 2>/dev/null | awk '{print $1}')"
if [[ "$before" == "$after" ]]; then
  ok "--dry-run não altera arquivo nenhum"
else
  bad "--dry-run ALTEROU arquivo (não pode)"
fi

# --- 7. Sem fonte utilizável → lista OFICIAL por distro -----------------
d="${WORK}/r7"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'deb [trusted=yes] file:///opt/apt-repo ./\n' > "$d/etc/apt/sources.list.d/ai-cpu-os-local.list"
: > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if grep -q 'archive.ubuntu.com/ubuntu noble main' "$d/etc/apt/sources.list"; then
  ok "sem fonte boa: grava a lista OFICIAL do Ubuntu (noble)"
else
  bad "não gravou a lista oficial do Ubuntu"
fi
if grep -q 'security.ubuntu.com' "$d/etc/apt/sources.list"; then
  ok "a lista do Ubuntu inclui o repositório de segurança"
else
  bad "faltou o repositório de segurança do Ubuntu"
fi

d="${WORK}/r8"; mk_root "$d" debian trixie; mk_apt_stub "$d"
: > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
if grep -q 'deb.debian.org/debian trixie main' "$d/etc/apt/sources.list"; then
  ok "sem fonte boa: grava a lista OFICIAL do Debian (trixie)"
else
  bad "não gravou a lista oficial do Debian"
fi

# --- 8. revert restaura o estado anterior -------------------------------
d="${WORK}/r9"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'deb [trusted=yes] file:///opt/apt-repo ./\n' > "$d/etc/apt/sources.list.d/ai-cpu-os-local.list"
printf 'ORIGINAL\n' > "$d/etc/apt/sources.list"
bash "$APPLY" --root "$d" >/dev/null 2>&1 || true
bash "$REVERT" --root "$d" --yes >/dev/null 2>&1 || true
if [[ -f "$d/etc/apt/sources.list.d/ai-cpu-os-local.list" ]]; then
  ok "revert DEVOLVE o arquivo problemático (estado anterior, como prometido)"
else
  bad "revert não devolveu o arquivo removido"
fi
if grep -q '^ORIGINAL' "$d/etc/apt/sources.list"; then
  ok "revert restaura o sources.list original a partir do backup"
else
  bad "revert não restaurou o sources.list"
fi

# --- 9. O apply diz o que fez com o teste do apt ------------------------
# Sem root/chroot ele NÃO consegue rodar o apt dentro da árvore: nesse caso tem
# de AVISAR (degradação explícita), nunca fingir que testou.
d="${WORK}/r10"; mk_root "$d" ubuntu noble; mk_apt_stub "$d"
printf 'deb [trusted=yes] file:///opt/apt-repo ./.\n' > "$d/etc/apt/sources.list.d/x.list"
printf 'deb http://archive.ubuntu.com/ubuntu noble main\n' > "$d/etc/apt/sources.list"
out="$(bash "$APPLY" --root "$d" 2>&1 || true)"
if grep -q "apt-get update" <<< "$out" && grep -qE "PULADO|testando com" <<< "$out"; then
  ok "o apply diz explicitamente se testou ou pulou o 'apt-get update'"
else
  bad "o apply não informa o que fez com o teste do apt"
fi
if grep -q "PULADO" <<< "$out" && ! grep -q "apt-get update' AINDA falha" <<< "$out"; then
  ok "sem chroot: degrada com AVISO (não aborta nem mente)"
else
  bad "sem chroot o apply não degradou como esperado"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "mod-apt-sources: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "mod-apt-sources: PASS=${PASS} FAIL=${FAIL}"
exit 1
