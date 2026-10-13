#!/usr/bin/env bash
#
# tests/smoke-test.sh — Testes rápidos pós-build do ai-cpu-os
# -----------------------------------------------------------------------------
# Verifica, de forma não destrutiva, se o tuning e os componentes principais
# foram aplicados. NÃO falha o pipeline por padrão (retorna 0 com resumo);
# use --strict para que qualquer falha resulte em exit != 0.
#
# Uso:
#   bash tests/smoke-test.sh [--dry-run] [--strict] \
#        [--role auto|inference|builder] [--family auto|<id>]
#
# Idempotente e somente leitura.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

DRY_RUN=0
STRICT=0
ROLE="auto"
FAMILY="auto"

PASS=0; FAIL=0; SKIP=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK"   "$(_ts)" "$*" "$C_RESET"; }

pass() { PASS=$((PASS+1)); printf '%b[PASS]%b %s\n' "$C_OK" "$C_RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '%b[FAIL]%b %s\n' "$C_ERR" "$C_RESET" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '%b[SKIP]%b %s\n' "$C_WARN" "$C_RESET" "$1"; }

check() {
  # check "descrição" "comando de verificação"
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] avaliaria: ${desc} → $*"
    return 0
  fi
  if eval "$*" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (comando: $*)"
  fi
}

# ---------------------------------------------------------------------------
# Resolver família + papel (delegado ao detect-hardware.sh)
# ---------------------------------------------------------------------------
resolve_targets() {
  local det="${REPO_ROOT}/detect-hardware.sh"
  local out=""
  if [[ -x "$det" ]]; then
    out="$("$det" --quiet 2>/dev/null || true)"
  fi
  if [[ "$FAMILY" == "auto" ]]; then
    FAMILY="$(printf '%s\n' "$out" | grep -E '^FAMILY=' | tail -1 | cut -d= -f2 || true)"
    [[ -z "$FAMILY" ]] && FAMILY="unknown"
  fi
  if [[ "$ROLE" == "auto" ]]; then
    ROLE="$(printf '%s\n' "$out" | grep -E '^ROLE=' | tail -1 | cut -d= -f2 || true)"
    [[ -z "$ROLE" ]] && ROLE="unknown"
  fi
  log_info "Alvo: família=${FAMILY} · papel=${ROLE}"
}

# ---------------------------------------------------------------------------
# Testes comuns (ambos os perfis)
# ---------------------------------------------------------------------------
test_common() {
  log_info "--- Testes comuns ---"

  check "sysctl vm.swappiness definido (<=10)" \
    '[[ "$(sysctl -n vm.swappiness 2>/dev/null || echo 999)" -le 10 ]]'

  check "sysctl vm.vfs_cache_pressure definido (<=100)" \
    '[[ "$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo 9999)" -le 100 ]]'

  check "sysctl net.core.rmem_max aumentado" \
    '[[ "$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)" -ge 134217728 ]]'

  check "Governor = performance em cpu0" \
    '[[ "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none)" == "performance" ]]'

  # THP: aceita 'always' ou 'madvise' (ambos benéficos); falha só em 'never'.
  if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    local thp
    thp="$(sed -E 's/.*\[([a-z]+)\].*/\1/' /sys/kernel/mm/transparent_hugepage/enabled)"
    if [[ "$thp" == "always" || "$thp" == "madvise" ]]; then
      pass "Transparent Huge Pages ativo (${thp})"
    else
      fail "Transparent Huge Pages desativado (${thp})"
    fi
  else
    skip "THP não exposto neste kernel/sistema"
  fi

  check "kernel.io_uring disponível (kernel >= 5.1)" \
    '[[ "$(uname -r | cut -d. -f1)" -gt 5 || ( "$(uname -r | cut -d. -f1)" -eq 5 && "$(uname -r | cut -d. -f2)" -ge 1 ) ]]'

  check "Arquivo /etc/sysctl.d/99-ai-tuning.conf presente" \
    '[[ -f /etc/sysctl.d/99-ai-tuning.conf ]]'

  check "AVX2 presente (necessário para performance)" \
    'grep -qm1 avx2 /proc/cpuinfo'

  # Aviso (não falha) sobre AVX-512
  if grep -qm1 avx512f /proc/cpuinfo; then
    log_warn "AVX-512 presente nesta CPU: só é usado se a família permitir (política optin/auto)."
  fi
}

# ---------------------------------------------------------------------------
# Testes do papel 'inference' (servidor de inferência em CPU)
# ---------------------------------------------------------------------------
test_inference() {
  log_info "--- Testes do papel inference ---"
  check "Binário llama-server compilado" \
    '[[ -x /opt/llama.cpp/build/bin/llama-server || -x /opt/llama.cpp/build/bin/main ]]'
  check "Unit ai-server.service instalado" \
    '[[ -f /etc/systemd/system/ai-server.service ]]'
  check "Usuário de serviço 'llama' existe" \
    'id llama'
  check "Diretório de modelos /opt/models existe" \
    '[[ -d /opt/models ]]'
  if command -v curl >/dev/null 2>&1; then
    if curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1; then
      pass "llama-server respondendo em :8080/health"
    else
      skip "llama-server não está rodando (ok se ainda não iniciado)"
    fi
  else
    skip "curl ausente; não foi possível checar :8080"
  fi
}

# ---------------------------------------------------------------------------
# Testes do papel 'builder' (build + registry + Gitea)
# ---------------------------------------------------------------------------
test_builder() {
  log_info "--- Testes do papel builder ---"
  check "Docker instalado" 'command -v docker'
  check "Docker daemon ativo" 'systemctl is-active --quiet docker'
  check "docker compose disponível" 'docker compose version'
  check "Registry respondendo em localhost:5000" \
    'curl -sf http://localhost:5000/v2/'
  check "Container 'registry' em execução" \
    'docker ps --format "{{.Names}}" | grep -qx registry'
  check "Container 'gitea' em execução" \
    'docker ps --format "{{.Names}}" | grep -qx gitea'

  # Alerta de single channel (não falha, apenas informa)
  if command -v dmidecode >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    local dimms
    dimms="$(dmidecode -t 17 2>/dev/null | grep -cE 'Size:.*[0-9]+ (MB|GB)' || true)"
    log_info "DIMMs populados: ${dimms:-?} — se <2 canais, ver alerta de single channel."
  else
    skip "dmidecode indisponível (precisa root) — não foi possível avaliar canais"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --strict)  STRICT=1; shift ;;
      --yes)     shift ;;   # smoke-test é não interativo; aceito por consistência
                            # (o build.sh repassa --yes a TODOS os filhos)
      --role)    [[ $# -ge 2 ]] || { log_error "--role exige valor"; exit 2; }; ROLE="$2"; shift 2 ;;
      --family)  [[ $# -ge 2 ]] || { log_error "--family exige valor"; exit 2; }; FAMILY="$2"; shift 2 ;;
      --profile) [[ $# -ge 2 ]] || { log_error "--profile exige valor"; exit 2; }
                 case "$2" in xeon) ROLE="inference" ;; ryzen) ROLE="builder" ;; *) ROLE="$2" ;; esac
                 shift 2 ;;
      -h|--help) echo "Uso: $0 [--dry-run] [--strict] [--yes] [--role auto|inference|builder] [--family auto|<id>]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  log_info "=== smoke-test.sh ==="
  resolve_targets

  test_common
  case "$ROLE" in
    inference) test_inference ;;
    builder)   test_builder ;;
    *)         log_warn "Papel '${ROLE}' indeterminado; rodando apenas os testes comuns." ;;
  esac

  printf '\n%bResumo:%b PASS=%d FAIL=%d SKIP=%d\n' "$C_INFO" "$C_RESET" "$PASS" "$FAIL" "$SKIP"

  if [[ $FAIL -gt 0 && $STRICT -eq 1 ]]; then
    log_error "Falhas detectadas e --strict ativo. Retornando 1."
    exit 1
  fi
  log_ok "smoke-test.sh concluído."
  return 0
}

main "$@"
