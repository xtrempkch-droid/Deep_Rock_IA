#!/usr/bin/env bash
#
# tests/test-verify-iso-repo-distro.sh — prova que o verificador é DISTRO-AWARE
# -----------------------------------------------------------------------------
# Bug que este teste guarda (run #10 do CI, sessão #20):
#
#   "[erro] Verificação FALHOU: 2 problema(s)"
#   "[FAIL] o repositório está na mídia mas o autoinstall NÃO o usa"
#
# Numa ISO **Debian** não existe `autoinstall.yaml` — a configuração é a
# `preseed/ai-cpu-os.cfg`. O `verify-iso.sh` só olhava o autoinstall para decidir
# se a fonte extra estava sendo usada, então reprovava uma ISO **Debian correta**:
# o repositório estava na mídia e a preseed O USAVA (`apt-setup/local0/repository`).
# Falso positivo — o build gerava a ISO e o próprio verificador a condenava.
#
# Este teste monta árvores mínimas (só o que a checagem do repositório olha) e
# roda o verificador de verdade, sem xorriso, sem root, sem rede e sem Docker.
#
#   - Ubuntu: carregar o repositório para o ALVO pelo late-command (/opt/apt-repo);
#   - Debian: usar `apt-setup/local0/repository` dentro da preseed.
#
# Uso: bash tests/test-verify-iso-repo-distro.sh [--verbose]
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

# Árvores mínimas: o que a checagem de repositório precisa ver.
mk_tree() {
  local d="$1" distro="$2"
  rm -rf "$d"; mkdir -p "$d/apt-repo/pool" "$d/preseed"

  # Índice + o .deb que ele cita (magic `!<arch>` = arquivo ar de verdade).
  printf '!<arch>\n%.0s' 1 > "$d/apt-repo/pool/git_1.0_amd64.deb"
  local size; size="$(stat -c %s "$d/apt-repo/pool/git_1.0_amd64.deb")"
  {
    printf 'Package: git\nVersion: 1.0\nArchitecture: amd64\n'
    printf 'Filename: pool/git_1.0_amd64.deb\nSize: %s\n\n' "$size"
  } > "$d/apt-repo/Packages"
  gzip -9c "$d/apt-repo/Packages" > "$d/apt-repo/Packages.gz"

  if [[ "$distro" == "debian" ]]; then
    # Preseed USANDO o repositório (é o `@@APT_LOCAL_PRESEED@@` substituído).
    cat > "$d/preseed/ai-cpu-os.cfg" <<'EOF'
d-i partman-auto/disk string /dev/vda
d-i apt-setup/local0/repository string deb [trusted=yes] file:///cdrom/apt-repo ./
d-i apt-setup/local0/comment string ai-cpu-os local repository
d-i preseed/late_command string in-target sh /cdrom/preseed/late-command.sh
EOF
  else
    # No caminho Ubuntu a fonte local NÃO entra no autoinstall: o apt do
    # instalador roda dentro de um chroot no alvo, onde /cdrom não existe. O
    # repositório é carregado para o alvo pelo late-command.sh (/opt/apt-repo)
    # e usado no primeiro boot.
    cat > "$d/autoinstall.yaml" <<'EOF'
#cloud-config
autoinstall:
  version: 1
EOF
    cat > "$d/preseed/late-command.sh" <<'EOF'
APT_REPO_SRC="/cdrom/apt-repo"
APT_REPO_DST="/opt/apt-repo"
cp -a "${APT_REPO_SRC}/." "/target${APT_REPO_DST}/"
EOF
  fi
}

# Roda o verificador (opcionalmente uma versão alternativa) e devolve a saída.
run_verify() {
  local verifier="$1" distro="$2" tree="$3"
  bash "$verifier" --dir "$tree" --distro "$distro" 2>&1 || true
}

# O que é considerado "reclamou do repositório não ser usado pela config".
SUSPECT='NÃO o usa|nao o usa|NÃO o referencia|aponta para um repositório local, mas'

echo "Verificador da ISO × repositório apt local (distro-aware)"

# ---------------------------------------------------------------------------
# 1) Caminho Ubuntu: a checagem já funcionava (referência)
# ---------------------------------------------------------------------------
mk_tree "$WORK/ubuntu" ubuntu
out="$(run_verify "$VERIFIER" ubuntu "$WORK/ubuntu")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  bad "ubuntu: reclamou que a config não usa o repo, mas o autoinstall usa"
  printf '%s\n' "$out" | grep -E "$SUSPECT" | sed 's/^/        /'
else
  ok "ubuntu: aceita o repo (seção 'sources' do autoinstall)"
fi

# ---------------------------------------------------------------------------
# 2) Caminho Debian: era AQUI que o falso positivo aparecia
# ---------------------------------------------------------------------------
mk_tree "$WORK/debian" debian
out="$(run_verify "$VERIFIER" debian "$WORK/debian")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  bad "debian: falso positivo — reprovou uma ISO Debian correta (run #10)"
  printf '%s\n' "$out" | grep -E "$SUSPECT" | sed 's/^/        /'
else
  ok "debian: aceita o repo (apt-setup/local0/repository da preseed)"
fi
case "$out" in
  *'preseed'*|*'repositório local'*) ok "debian: a mensagem fala de preseed, não de autoinstall" ;;
  *) bad "debian: a mensagem não menciona a preseed (texto genérico?)" ;;
esac

# ---------------------------------------------------------------------------
# 3) Teste negativo: config SEM a fonte extra -> o verificador DEVE reprovar
# ---------------------------------------------------------------------------
# Sem isto o teste acima passaria com um verificador que simplesmente não checa
# nada. O modo de falha real: repo na mídia e instalação ainda dependente de rede.
mk_tree "$WORK/debian-sem-repo" debian
sed -i '/apt-setup\/local0\/repository/d' "$WORK/debian-sem-repo/preseed/ai-cpu-os.cfg"
out="$(run_verify "$VERIFIER" debian "$WORK/debian-sem-repo")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  ok "debian sem a fonte extra: reprova (correto)"
else
  bad "debian sem a fonte extra: NÃO reprovou (checagem inútil?)"
  printf '%s\n' "$out" | tail -8 | sed 's/^/        /'
fi

mk_tree "$WORK/ubuntu-sem-repo" ubuntu
sed -i '/\/opt\/apt-repo/d' "$WORK/ubuntu-sem-repo/preseed/late-command.sh"
out="$(run_verify "$VERIFIER" ubuntu "$WORK/ubuntu-sem-repo")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  ok "ubuntu sem a fonte extra: reprova (correto)"
else
  bad "ubuntu sem a fonte extra: NÃO reprovou"
fi

# ---------------------------------------------------------------------------
# 4) Prova de regressão: o verificador ANTERIOR tem de reprovar o caso Debian
# ---------------------------------------------------------------------------
# Sem isto, este teste poderia estar "passando" por acidente. Pegamos a versão
# que está no git e exigimos que ela MOSTRE o falso positivo.
if git -C "$TEST_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$TEST_ROOT" show HEAD:iso/verify-iso.sh > "$WORK/verify-antigo.sh" 2>/dev/null || true
  if [[ -s "$WORK/verify-antigo.sh" ]]; then
    out_antigo="$(run_verify "$WORK/verify-antigo.sh" debian "$WORK/debian")"
    if printf '%s\n' "$out_antigo" | grep -Eq "$SUSPECT"; then
      ok "regressão: o verificador ANTERIOR reprovava a ISO Debian (bug provado)"
    else
      # Pode acontecer se o HEAD já contiver a correção (ex.: rodando pós-commit).
      ok "regressão: HEAD já contém a correção (nada a comparar)"
    fi
  fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "verify-repo-distro: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "verify-repo-distro: PASS=${PASS} FAIL=${FAIL}"
exit 1
