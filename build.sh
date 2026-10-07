#!/usr/bin/env bash
#
# build.sh — Orquestrador principal do ai-cpu-os
# -----------------------------------------------------------------------------
# Transforma um Debian/Ubuntu minimal em um sistema otimizado para inferência
# de LLMs 100% em CPU, aplicando tuning de kernel comum e delegando para o
# perfil escolhido (xeon | ryzen).
#
# Uso:
#   sudo ./build.sh --profile auto            # detecta e aplica
#   sudo ./build.sh --profile xeon            # força perfil xeon
#   sudo ./build.sh --profile ryzen           # força perfil ryzen
#   sudo ./build.sh --profile auto --dry-run  # simula, não aplica
#   sudo ./build.sh --profile auto --yes      # não pede confirmação
#
# Regras de qualidade: set -euo pipefail, logs com timestamp e nível,
# idempotência, --dry-run, confirmação antes de ações sensíveis.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes e caminhos
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly COMMON_DIR="${SCRIPT_DIR}/common"
readonly PROFILES_DIR="${SCRIPT_DIR}/profiles"
readonly TESTS_DIR="${SCRIPT_DIR}/tests"
readonly LOG_FILE="/var/log/ai-cpu-os-build.log"

PROFILE="auto"
DRY_RUN=0
ASSUME_YES=0
SKIP_TESTS=0
SKIP_COMMON=0

# Cores (desativadas se não for TTY)
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi

# ---------------------------------------------------------------------------
# Logging — timestamp + nível, e espelho em arquivo quando possível
# ---------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local color="" ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    INFO)  color="$C_INFO" ;;
    WARN)  color="$C_WARN" ;;
    ERROR) color="$C_ERR"  ;;
    OK)    color="$C_OK"   ;;
  esac
  printf '%b[%s] [%-5s] %s%b\n' "$color" "$ts" "$level" "$*" "$C_RESET"
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@" >&2; }
log_ok()    { _log OK    "$@"; }

# Inicia espelhamento em arquivo (best-effort; requer permissão de escrita).
start_file_log() {
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Log espelhado em ${LOG_FILE}"
  else
    log_warn "Não foi possível escrever em ${LOG_FILE} (sem permissão). Continuando apenas no stdout."
  fi
}

# Executa um comando, respeitando --dry-run.
# Uso: run "descrição" cmd arg1 arg2 ...
run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] ${desc}: $*"
    return 0
  fi
  log_info "${desc}: $*"
  "$@"
}

# Confirmação interativa (pulada com --yes ou --dry-run).
confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  local reply
  read -r -p "${prompt} [s/N] " reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# Uso / ajuda
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
build.sh — ai-cpu-os

Uso:
  sudo ./build.sh [opções]

Opções:
  --profile <auto|xeon|ryzen>  Perfil a aplicar (padrão: auto).
  --dry-run                    Simula, sem alterar o sistema.
  --yes                        Não pede confirmação (automação/CI).
  --skip-common                Não aplica tuning de kernel comum.
  --skip-tests                 Não roda o smoke-test ao final.
  -h, --help                   Mostra esta ajuda.

Variável de ambiente:
  AI_PROFILE                   Alternativa a --profile.

Exemplos:
  sudo ./build.sh --profile auto
  sudo ./build.sh --profile xeon --dry-run
  sudo ./build.sh --profile ryzen --yes
EOF
}

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        [[ $# -ge 2 ]] || { log_error "--profile exige um valor."; exit 2; }
        PROFILE="$2"; shift 2 ;;
      --dry-run)     DRY_RUN=1; shift ;;
      --yes)         ASSUME_YES=1; shift ;;
      --skip-common) SKIP_COMMON=1; shift ;;
      --skip-tests)  SKIP_TESTS=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  # Variável de ambiente como fallback
  if [[ "$PROFILE" == "auto" && -n "${AI_PROFILE:-}" ]]; then
    PROFILE="$AI_PROFILE"
  fi

  case "$PROFILE" in
    auto|xeon|ryzen) ;;
    *) log_error "Perfil inválido: '${PROFILE}'. Use auto, xeon ou ryzen."; exit 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Pré-checagens
# ---------------------------------------------------------------------------
check_root() {
  # --dry-run pode rodar sem root (apenas inspeção), mas avisamos.
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_warn "Rodando --dry-run sem root: a detecção de RAM/canais pode ser incompleta."
    else
      log_error "Este script precisa de root. Use: sudo ./build.sh ..."
      exit 1
    fi
  fi
}

check_os() {
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; ver="${VERSION_ID:-}"
  fi
  case "$id" in
    debian)
      if [[ "${ver%%.*}" -lt 12 ]]; then
        log_error "Debian ${ver} detectado. Requerido Debian 12+ (Bookworm)."
        exit 1
      fi
      ;;
    ubuntu)
      # Compara "22.04" ou superior de forma simples
      if [[ "${ver%%.*}" -lt 22 ]]; then
        log_error "Ubuntu ${ver} detectado. Requerido Ubuntu 22.04+."
        exit 1
      fi
      ;;
    "")
      log_warn "Não foi possível ler /etc/os-release; prosseguindo por sua conta e risco."
      ;;
    *)
      log_warn "Distro '${id}' não é oficialmente suportada (Debian/Ubuntu). Prosseguindo, mas pode falhar."
      ;;
  esac
  log_ok "Sistema operacional aceito: ${id:-desconhecido} ${ver:-}"
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    log_error "Arquivo obrigatório não encontrado: $f"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Detecção de perfil via detect-hardware.sh
# ---------------------------------------------------------------------------
resolve_profile() {
  if [[ "$PROFILE" != "auto" ]]; then
    log_info "Perfil forçado manualmente: '${PROFILE}'."
    return 0
  fi

  local detector="${SCRIPT_DIR}/detect-hardware.sh"
  require_file "$detector"

  log_info "Perfil 'auto': executando detect-hardware.sh..."
  # detect-hardware.sh imprime a linha 'PROFILE=<nome>' no final.
  local detected
  detected="$("$detector" --quiet 2>/dev/null | grep -E '^PROFILE=' | tail -1 | cut -d= -f2 || true)"

  case "$detected" in
    xeon|ryzen)
      PROFILE="$detected"
      log_ok "Perfil detectado: '${PROFILE}'."
      ;;
    *)
      log_error "Não foi possível detectar o perfil automaticamente."
      log_error "Rode './detect-hardware.sh' para inspecionar e use --profile xeon|ryzen."
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Etapas
# ---------------------------------------------------------------------------
# Constrói (via echo) as flags repassadas aos scripts filhos.
# Emitidas uma por linha para consumo com mapfile.
child_flags() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' --dry-run; fi
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' --yes; fi
  return 0
}

run_common_tuning() {
  if [[ $SKIP_COMMON -eq 1 ]]; then
    log_warn "Tuning comum pulado (--skip-common)."
    return 0
  fi
  log_info "=== Etapa 1/4: Tuning de kernel comum ==="
  local s
  local -a flags=()
  mapfile -t flags < <(child_flags)
  for s in kernel-tuning.sh hugepages.sh governor.sh; do
    require_file "${COMMON_DIR}/${s}"
    run "Aplicando common/${s}" bash "${COMMON_DIR}/${s}" "${flags[@]+"${flags[@]}"}"
  done
}

run_profile_install() {
  log_info "=== Etapa 2/4: Instalação do perfil '${PROFILE}' ==="
  local installer="${PROFILES_DIR}/${PROFILE}/install.sh"
  require_file "$installer"
  local -a flags=()
  mapfile -t flags < <(child_flags)
  run "Executando ${installer}" bash "$installer" "${flags[@]+"${flags[@]}"}"
}

run_verification() {
  log_info "=== Etapa 3/4: Verificação do tuning ==="
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Pularia verificação de sysctl/governor/THP."
    return 0
  fi
  local swapp vfs numa
  swapp="$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  vfs="$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo '?')"
  numa="$(sysctl -n kernel.numa_balancing 2>/dev/null || echo '?')"
  log_info "vm.swappiness=${swapp} · vm.vfs_cache_pressure=${vfs} · kernel.numa_balancing=${numa}"

  local gov
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
  log_info "governor[cpu0]=${gov}"

  local thp
  thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
  log_info "transparent_hugepage=${thp}"
}

run_tests() {
  if [[ $SKIP_TESTS -eq 1 ]]; then
    log_warn "Smoke-test pulado (--skip-tests)."
    return 0
  fi
  log_info "=== Etapa 4/4: Smoke-test ==="
  local t="${TESTS_DIR}/smoke-test.sh"
  if [[ ! -f "$t" ]]; then
    log_warn "smoke-test.sh não encontrado; pulando."
    return 0
  fi
  run "Rodando smoke-test" bash "$t" $([[ $DRY_RUN -eq 1 ]] && echo "--dry-run") || {
    log_warn "Smoke-test reportou falhas (não fatais nesta fase). Veja a saída acima."
  }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
banner() {
  cat <<'EOF'
  ___   _____      ______ __   __  ___  ____
 / _ \ |_   _|    / ____/| |  | |/ _ \/ ___|
| |_| |  | |_____| |     | |  | | | | \___ \
|  _  |  | |_____| |___  | |__| | |_| |___) |
|_| |_|  |_|      \____|  \____/ \___/|____/
             ai-cpu-os  ·  "1% importa"
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  banner
  log_info "ai-cpu-os build.sh — início"
  log_info "Argumentos: profile=${PROFILE} dry_run=${DRY_RUN} yes=${ASSUME_YES}"

  start_file_log
  check_root
  check_os

  log_warn "LEMBRETE: Xeon E5-2678 v3 e Ryzen 5 3500X NÃO possuem AVX-512 (apenas AVX2)."
  log_warn "LEMBRETE: RX 580 apenas para vídeo; single channel no Ryzen custa ~50% de banda."

  resolve_profile

  if [[ "$PROFILE" == "ryzen" ]]; then
    log_warn "Perfil 'ryzen' detectado: verifique o alerta de single channel no install."
  fi

  if ! confirm "Aplicar tuning e instalar perfil '${PROFILE}' agora?"; then
    log_warn "Cancelado pelo usuário."
    exit 0
  fi

  run_common_tuning
  run_profile_install
  run_verification
  run_tests

  log_ok "Concluído (perfil '${PROFILE}')."

  # Avisos de follow-up (reboot pendente, modelo, etc.)
  if [[ $DRY_RUN -eq 0 ]]; then
    log_info "Ações de follow-up possíveis:"
    log_info "  - Se alterou C-states (cmdline), reinicie: sudo reboot"
    log_info "  - Se for o perfil xeon, baixe um modelo e suba o serviço:"
    log_info "      sudo systemctl enable --now ai-server"
    log_info "  - Meça performance: llama-bench (ver README)."
    log_info "  - Atualize docs/STATE.md com os resultados (regra do AGENTS.md)."
  fi
}

main "$@"
