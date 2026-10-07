#!/usr/bin/env bash
#
# profiles/ryzen/registry-setup.sh — Registry Docker privado (localhost:5000)
# -----------------------------------------------------------------------------
# Sobe um container 'registry:2' em localhost:5000 com volume persistente,
# configurando o Docker para aceitar o registry como insecure (sem TLS) —
# adequado para uso local/privado.
#
# Uso:
#   sudo bash profiles/ryzen/registry-setup.sh [--dry-run] [--yes]
#                                              [--port 5000] [--data-dir /var/lib/registry]
#
# Idempotente.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
REG_PORT="5000"
REG_NAME="registry"
DATA_DIR="/var/lib/registry"

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

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_warn "Docker não encontrado (dry-run: continuando a simulação)."
      return 0
    fi
    log_error "Docker não encontrado. Rode primeiro: sudo bash profiles/ryzen/docker-setup.sh"
    exit 1
  fi
  if [[ $DRY_RUN -eq 0 ]] && ! docker info >/dev/null 2>&1; then
    log_error "Não foi possível falar com o daemon Docker. Verifique: systemctl status docker"
    exit 1
  fi
}

ensure_insecure_registry() {
  local daemon_json="/etc/docker/daemon.json"
  local entry="localhost:${REG_PORT}"
  log_info "Garantindo '${entry}' em insecure-registries..."
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] garantiria ${entry} em ${daemon_json} e reiniciaria o Docker"
    return 0
  fi
  install -m 0755 -d /etc/docker
  if [[ -f "$daemon_json" ]] && grep -q "${entry}" "$daemon_json"; then
    log_info "Já presente em ${daemon_json} (idempotente)."
  else
    local tmp; tmp="$(mktemp)"
    if [[ -f "$daemon_json" ]]; then
      if command -v jq >/dev/null 2>&1; then
        jq --arg e "$entry" '.["insecure-registries"] = ((.["insecure-registries"] // []) + [$e] | unique)' \
          "$daemon_json" > "$tmp"
      else
        log_warn "jq ausente; reescrevendo daemon.json com defaults + registry."
        printf '{ "insecure-registries": ["%s"] }\n' "$entry" > "$tmp"
      fi
      cp -a "$daemon_json" "${daemon_json}.bak.$(date +%s)"
    else
      printf '{ "insecure-registries": ["%s"] }\n' "$entry" > "$tmp"
    fi
    install -m 0644 "$tmp" "$daemon_json"
    rm -f "$tmp"
    log_ok "daemon.json atualizado."
    run "Reiniciando Docker" systemctl restart docker
  fi
}

start_registry() {
  run "Criando ${DATA_DIR}" install -d -m 0755 "$DATA_DIR"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] docker run -d --name ${REG_NAME} -p ${REG_PORT}:5000 -v ${DATA_DIR}:/var/lib/registry registry:2"
    return 0
  fi

  if docker ps -a --format '{{.Names}}' | grep -qx "$REG_NAME"; then
    if docker ps --format '{{.Names}}' | grep -qx "$REG_NAME"; then
      log_info "Registry '${REG_NAME}' já está rodando (idempotente)."
    else
      run "Iniciando registry existente" docker start "$REG_NAME"
    fi
  else
    run "Baixando registry:2" docker pull registry:2
    run "Executando registry" docker run -d \
      --name "$REG_NAME" \
      --restart unless-stopped \
      -p "127.0.0.1:${REG_PORT}:5000" \
      -v "${DATA_DIR}:/var/lib/registry" \
      registry:2
  fi
}

verify_registry() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] curl -sf http://localhost:${REG_PORT}/v2/ && docker ps"
    return 0
  fi
  local ok=0
  for _ in 1 2 3 4 5; do
    if curl -sf "http://localhost:${REG_PORT}/v2/" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok -eq 1 ]]; then
    log_ok "Registry respondendo em http://localhost:${REG_PORT}/v2/"
    log_info "Use tags no formato: localhost:${REG_PORT}/<imagem>:<tag>"
  else
    log_warn "Registry não respondeu em http://localhost:${REG_PORT}/v2/. Veja: docker logs ${REG_NAME}"
  fi

  log_info "Dica de limpeza de espaço (garbage collection):"
  log_info "  docker exec -it ${REG_NAME} registry garbage-collect -m /etc/docker/registry/config.yml"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)  DRY_RUN=1; shift ;;
      --yes)      ASSUME_YES=1; shift ;;
      --port)     [[ $# -ge 2 ]] || { log_error "--port exige valor"; exit 2; }; REG_PORT="$2"; shift 2 ;;
      --data-dir) [[ $# -ge 2 ]] || { log_error "--data-dir exige valor"; exit 2; }; DATA_DIR="$2"; shift 2 ;;
      -h|--help)  echo "Uso: $0 [--dry-run] [--yes] [--port 5000] [--data-dir /var/lib/registry]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  log_info "=== registry-setup.sh (registry privado em localhost:${REG_PORT}) ==="
  require_docker
  ensure_insecure_registry
  start_registry
  verify_registry
  log_ok "registry-setup.sh concluído."
}

main "$@"
