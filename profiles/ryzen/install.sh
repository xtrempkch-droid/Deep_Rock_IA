#!/usr/bin/env bash
#
# profiles/ryzen/install.sh — Perfil ryzen (Build + Registry + Gitea)
# -----------------------------------------------------------------------------
# Orquestra a instalação do perfil de build:
#   1. Docker Engine + Compose (docker-setup.sh)
#   2. Registry privado em localhost:5000 (registry-setup.sh)
#   3. Gitea via docker compose (gitea-compose.yml)
#   4. Alerta explícito de single channel (perda de ~50% de banda)
#
# Uso:
#   sudo bash profiles/ryzen/install.sh [--dry-run] [--yes] [--skip-docker]
#                                       [--skip-registry] [--skip-gitea]
#
# Idempotente.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT

DRY_RUN=0
ASSUME_YES=0
SKIP_DOCKER=0
SKIP_REGISTRY=0
SKIP_GITEA=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK"   "$(_ts)" "$*" "$C_RESET"; }

run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then log_info "[dry-run] ${desc}: $*"; return 0; fi
  log_info "${desc}: $*"
  "$@"
}

confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then return 0; fi
  local reply; read -r -p "${prompt} [s/N] " reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# Alerta de single channel (o problema de hardware mais crítico deste perfil)
# ---------------------------------------------------------------------------
alert_single_channel() {
  local populated=0
  if command -v dmidecode >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    populated="$(dmidecode -t 17 2>/dev/null | grep -cE 'Size:.*[0-9]+ (MB|GB)' || true)"
  fi

  log_info "Memória total: $(awk '/^MemTotal:/{printf \"%.1f GiB\", $2/1048576}' /proc/meminfo) · DIMMs detectados: ${populated:-?}"

  # Heurística: se 64 GB com 4x16 GB mas apenas 1 canal ativo → alerta.
  # Como a detecção exata é difícil sem DMI completo, alertamos sempre que a
  # configuração sugerir risco, além de reforçar o alerta geral.
  log_warn "==================================================================="
  log_warn " ALERTA DE MEMÓRIA — SINGLE CHANNEL"
  log_warn " Este perfil assume um Ryzen 5 3500X operando em SINGLE CHANNEL,"
  log_warn " o que reduz a banda de memória em ~50%."
  log_warn " Para inferência em CPU isso é crítico; para builds, afeta menos"
  log_warn " mas ainda assim importa."
  log_warn ""
  log_warn " AÇÃO RECOMENDADA:"
  log_warn "   Em placas MSI B550 (AM4), instale os pentes nos slots A2 + B2"
  log_warn "   (2º e 4º, contando do soquete da CPU) para habilitar dual channel."
  log_warn "   Confirme com: sudo dmidecode -t memory | grep -E 'Locator|Size'"
  log_warn "==================================================================="

  if confirm "Entendi o alerta de memória. Continuar com a instalação?"; then
    return 0
  fi
  log_warn "Instalação pausada pelo usuário após o alerta de memória."
  exit 0
}

# ---------------------------------------------------------------------------
# Etapas
# ---------------------------------------------------------------------------
step_docker() {
  if [[ $SKIP_DOCKER -eq 1 ]]; then
    log_warn "Docker pulado (--skip-docker)."
    return 0
  fi
  log_info "--- Etapa: Docker Engine + Compose ---"
  local flags=()
  if [[ $DRY_RUN -eq 1 ]]; then flags+=(--dry-run); fi
  if [[ $ASSUME_YES -eq 1 ]]; then flags+=(--yes); fi
  run "Executando docker-setup.sh" bash "${SCRIPT_DIR}/docker-setup.sh" "${flags[@]+"${flags[@]}"}"
}

step_registry() {
  if [[ $SKIP_REGISTRY -eq 1 ]]; then
    log_warn "Registry pulado (--skip-registry)."
    return 0
  fi
  log_info "--- Etapa: Registry privado localhost:5000 ---"
  local flags=()
  if [[ $DRY_RUN -eq 1 ]]; then flags+=(--dry-run); fi
  if [[ $ASSUME_YES -eq 1 ]]; then flags+=(--yes); fi
  run "Executando registry-setup.sh" bash "${SCRIPT_DIR}/registry-setup.sh" "${flags[@]+"${flags[@]}"}"
}

step_gitea() {
  if [[ $SKIP_GITEA -eq 1 ]]; then
    log_warn "Gitea pulado (--skip-gitea)."
    return 0
  fi
  log_info "--- Etapa: Gitea (docker compose) ---"
  local compose_file="${SCRIPT_DIR}/gitea-compose.yml"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] docker compose -f ${compose_file} up -d"
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker ausente; não é possível subir o Gitea."
    return 1
  fi

  run "Criando diretório de dados" mkdir -p "${SCRIPT_DIR}/data/gitea"
  ( cd "$SCRIPT_DIR" && docker compose -f "$compose_file" up -d )

  log_info "Aguardando Gitea na porta 3000..."
  local ok=0
  for _ in $(seq 1 15); do
    if curl -sf "http://localhost:3000/" >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
  if [[ $ok -eq 1 ]]; then
    log_ok "Gitea disponível em http://localhost:3000/"
  else
    log_warn "Gitea ainda não respondeu. Veja: docker logs gitea"
  fi
}

print_next_steps() {
  log_info "Próximos passos do perfil ryzen:"
  log_info "  1. Registry:  http://localhost:5000/v2/_catalog"
  log_info "  2. Gitea:     http://localhost:3000/ (crie o admin no primeiro acesso)"
  log_info "  3. Build:     ${SCRIPT_DIR}/build-runner.sh --context /caminho/repo \\"
  log_info "                    --tag localhost:5000/meu/app:1.0 --push"
  log_info "  4. Vídeo:     use a RX 580 apenas para saída de vídeo (nunca computação)."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=1; shift ;;
      --yes)            ASSUME_YES=1; shift ;;
      --skip-docker)    SKIP_DOCKER=1; shift ;;
      --skip-registry)  SKIP_REGISTRY=1; shift ;;
      --skip-gitea)     SKIP_GITEA=1; shift ;;
      -h|--help)
        echo "Uso: $0 [--dry-run] [--yes] [--skip-docker] [--skip-registry] [--skip-gitea]"
        exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  printf '%b=== install.sh (perfil ryzen · build + registry + Gitea) ===%b\n' "$C_BOLD" "$C_RESET"
  alert_single_channel

  step_docker
  step_registry
  step_gitea
  print_next_steps

  log_ok "install.sh (ryzen) concluído."
  log_info "Referências: ${REPO_ROOT}/docs/TUNING.md e docs/TROUBLESHOOTING.md"
}

main "$@"
