#!/usr/bin/env bash
#
# profiles/ryzen/docker-setup.sh — Instala Docker Engine + Compose (oficial)
# -----------------------------------------------------------------------------
# Instala o Docker a partir do repositório oficial da Docker (não o pacote
# 'docker.io' do Debian, que costuma ser mais antigo), configura o daemon para
# aceitar o registry inseguro em localhost:5000 e habilita o serviço.
#
# Uso:
#   sudo bash profiles/ryzen/docker-setup.sh [--dry-run] [--yes]
#
# Idempotente.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
DOCKER_USER="${SUDO_USER:-${USER:-}}"

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

# ---------------------------------------------------------------------------
# Etapas
# ---------------------------------------------------------------------------
install_docker_repo() {
  log_info "Configurando repositório oficial do Docker..."
  run "apt update" apt-get update
  run "Instalando pré-requisitos" apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg jq

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] adicionaria a chave GPG e o repositório oficial do Docker"
    return 0
  fi

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
}

install_docker_pkgs() {
  log_info "Instalando Docker Engine, CLI, containerd e plugins..."
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log_info "Docker e Compose já instalados (idempotente)."
    return 0
  fi
  run "Instalando pacotes Docker" apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

configure_daemon() {
  local daemon_json="/etc/docker/daemon.json"
  log_info "Configurando /etc/docker/daemon.json (insecure-registry local)..."

  # Objetivo: permitir push/pull em localhost:5000 sem TLS.
  # Também limita logs e usa o driver de storage padrão.
  local desired
  desired="$(cat <<'JSON'
{
  "insecure-registries": ["localhost:5000", "127.0.0.1:5000"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "default-address-pools": [
    { "base": "172.30.0.0/16", "size": 24 }
  ]
}
JSON
)"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] escreveria ${daemon_json}:"
    sed 's/^/    | /' <<<"$desired"
    return 0
  fi

  local tmp; tmp="$(mktemp)"
  printf '%s\n' "$desired" > "$tmp"
  if [[ -f "$daemon_json" ]] && cmp -s "$tmp" "$daemon_json"; then
    log_info "daemon.json já atualizado (idempotente)."
  else
    if [[ -f "$daemon_json" ]]; then
      cp -a "$daemon_json" "${daemon_json}.bak.$(date +%s)"
    fi
    install -m 0644 "$tmp" "$daemon_json"
    log_ok "daemon.json atualizado (backup criado, se havia um)."
  fi
  rm -f "$tmp"
}

enable_docker() {
  run "Habilitando e iniciando Docker" systemctl enable --now docker
  if [[ -n "$DOCKER_USER" && "$DOCKER_USER" != "root" ]]; then
    if id -nG "$DOCKER_USER" 2>/dev/null | grep -qw docker; then
      log_info "Usuário '${DOCKER_USER}' já está no grupo docker."
    else
      log_info "Adicionando '${DOCKER_USER}' ao grupo docker (relogue para efetivar)."
      run "Adicionando ao grupo docker" usermod -aG docker "$DOCKER_USER"
    fi
  fi
}

verify() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] docker --version && docker compose version"
    return 0
  fi
  docker --version || log_warn "docker --version falhou."
  docker compose version || log_warn "docker compose version falhou."
  if systemctl is-active --quiet docker; then
    log_ok "Docker está ativo."
  else
    log_warn "Docker não está ativo. Verifique: journalctl -u docker -n 50"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      --yes)     ASSUME_YES=1; shift ;;
      -h|--help) echo "Uso: $0 [--dry-run] [--yes]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  log_info "=== docker-setup.sh (Docker Engine + Compose) ==="
  install_docker_repo
  install_docker_pkgs
  configure_daemon
  enable_docker
  verify
  log_ok "docker-setup.sh concluído."
}

main "$@"
