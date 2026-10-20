#!/usr/bin/env bash
#
# tests/test-verify-iso-repo.sh — prova que o verificador cobra o repositório
# local na mídia e o uso dele no late-command
# -----------------------------------------------------------------------------
# História (importa para não regredir):
#
#   Run #10 do CI (sessão #20): "[erro] Verificação FALHOU: 2 problema(s)" e
#   "[FAIL] o repositório está na mídia mas o autoinstall NÃO o usa".
#
#   A checagem nasceu distro-aware porque o Debian não tem autoinstall. Com a
#   base única (ADR-001, sessão #42), o mecanismo é UM só: o repositório NÃO
#   entra no apt do instalador (o curtin roda num chroot sem /cdrom); ele é
#   carregado para o ALVO pelo late-command (/opt/apt-repo) e usado no 1º boot.
#
# O que este teste guarda hoje:
#   1. repo na mídia + late-command com /opt/apt-repo  → passa;
#   2. repo na mídia + late-command SEM a referência    → REPROVA (modo de falha
#      real: centenas de MB inúteis e alvo dependente de rede);
#   3. sem repo e sem referência                         → passa (SKIP);
#   4. autoinstall ausente                               → REPROVA;
#   5. `--distro debian`                                 → recusado (ADR-001).
#
# Sem xorriso, sem root, sem rede e sem Docker: monta árvores mínimas e roda o
# verificador de verdade com --dir.
#
# Uso: bash tests/test-verify-iso-repo.sh [--verbose]
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

# Árvore mínima: só o que as checagens olham.
mk_tree() {
  local d="$1" with_repo="$2" with_ref="$3"
  rm -rf "$d"
  mkdir -p "$d/ai-cpu-os-boot" "$d/boot/grub"

  cat > "$d/autoinstall.yaml" <<'EOF'
version: 1
identity:
  username: ai-cpu-os
  hostname: ai-cpu-os
  password: "$6$exemplo$hash"
storage:
  layout: {name: direct}
late-commands:
  - AI_CURTIN=1 sh /cdrom/ai-cpu-os-boot/late-command.sh
shutdown: reboot
EOF

  cat > "$d/boot/grub/grub.cfg" <<'EOF'
set default="ai-cpu-os-auto"
menuentry "ai-cpu-os" --id ai-cpu-os-auto {
  linux /casper/vmlinuz autoinstall ---
}
EOF

  : > "$d/ai-cpu-os-boot/firstboot.sh"
  : > "$d/ai-cpu-os-boot/ai-cpu-os-firstboot.service"

  {
    echo '#!/bin/sh'
    echo 'NETWORK_MODE=auto'
    if [[ "$with_ref" == "yes" ]]; then
      echo 'APT_REPO_SRC="/cdrom/apt-repo"'
      echo 'APT_REPO_DST="/opt/apt-repo"'
      echo 'cp -a "${APT_REPO_SRC}/." "/target${APT_REPO_DST}/"'
    fi
    echo "ROOT_PASSWORD_HASH=''"
  } > "$d/ai-cpu-os-boot/late-command.sh"

  if [[ "$with_repo" == "yes" ]]; then
    mkdir -p "$d/apt-repo/pool"
    printf '!<arch>\n' > "$d/apt-repo/pool/git_1.0_amd64.deb"
    local size; size="$(stat -c %s "$d/apt-repo/pool/git_1.0_amd64.deb")"
    {
      printf 'Package: git\nVersion: 1.0\nArchitecture: amd64\n'
      printf 'Filename: pool/git_1.0_amd64.deb\nSize: %s\n\n' "$size"
    } > "$d/apt-repo/Packages"
    gzip -9c "$d/apt-repo/Packages" > "$d/apt-repo/Packages.gz"
  fi
}

run_verify() { bash "$VERIFIER" --dir "$1" 2>&1 || true; }

SUSPECT='NÃO o referencia|NÃO o usa|nao o usa'

echo "Verificador da ISO × repositório apt local (base única)"

# 1) repo na mídia + late-command que o usa -> não pode reclamar
mk_tree "$WORK/ok" yes yes
out="$(run_verify "$WORK/ok")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  bad "repo na mídia e late-command usando /opt/apt-repo: reclamou (falso positivo)"
  printf '%s\n' "$out" | grep -E "$SUSPECT" | sed 's/^/        /'
else
  ok "repo na mídia + /opt/apt-repo no late-command: aceito"
fi

# 2) repo na mídia SEM a referência -> tem de reprovar
mk_tree "$WORK/sem-ref" yes no
out="$(run_verify "$WORK/sem-ref")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  ok "repo na mídia sem referência no late-command: reprova (correto)"
else
  bad "repo na mídia sem referência: NÃO reprovou (checagem inútil?)"
  printf '%s\n' "$out" | tail -8 | sed 's/^/        /'
fi

# 3) sem repo e sem referência -> passa (SKIP, instalação exige rede)
mk_tree "$WORK/sem-repo" no no
out="$(run_verify "$WORK/sem-repo")"
if printf '%s\n' "$out" | grep -Eq "$SUSPECT"; then
  bad "sem repositório na mídia: reprovou (deveria ser SKIP, não FAIL)"
  printf '%s\n' "$out" | grep -E "$SUSPECT" | sed 's/^/        /'
else
  ok "sem repositório na mídia: SKIP (não é erro)"
fi

# 4) Teste negativo do próprio verificador: sem autoinstall tem de reprovar
mk_tree "$WORK/sem-autoinstall" yes yes
rm -f "$WORK/sem-autoinstall/autoinstall.yaml"
out="$(run_verify "$WORK/sem-autoinstall")"
if printf '%s\n' "$out" | grep -q 'AUSENTE'; then
  ok "sem autoinstall.yaml: reprova (o verificador não é decorativo)"
else
  bad "sem autoinstall.yaml: NÃO reprovou"
  printf '%s\n' "$out" | tail -8 | sed 's/^/        /'
fi

# 5) O caminho antigo (--distro debian) tem de ser recusado com mensagem clara
out="$(bash "$VERIFIER" --dir "$WORK/ok" --distro debian 2>&1 || true)"
if printf '%s\n' "$out" | grep -qi 'ADR-001'; then
  ok "--distro debian: recusado com mensagem que aponta o ADR-001"
else
  bad "--distro debian: não foi recusado com a mensagem esperada"
fi

# 6) Os caminhos da mídia são os novos (sem /preseed)
mk_tree "$WORK/check-paths" yes yes
out="$(run_verify "$WORK/check-paths")"
if printf '%s\n' "$out" | grep -q '/ai-cpu-os-boot/late-command.sh'; then
  ok "verificador confere /ai-cpu-os-boot/late-command.sh"
else
  bad "verificador não confere o caminho novo do late-command"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "verify-repo: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "verify-repo: PASS=${PASS} FAIL=${FAIL}"
exit 1
