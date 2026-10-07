#!/usr/bin/env bash
#
# profiles/xeon/install.sh — Perfil xeon (servidor de inferência em CPU)
# -----------------------------------------------------------------------------
# Instala dependências, compila o llama.cpp (via llama-build.sh), aplica o
# sysctl do perfil, cria o usuário de serviço, instala a unit systemd e
# (opcionalmente) baixa um modelo pequeno.
#
# Uso:
#   sudo bash profiles/xeon/install.sh [--dry-run] [--yes]
#                                      [--download-model URL]
#                                      [--model-path /opt/models/model.gguf]
#
# Idempotente.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DRY_RUN=0
ASSUME_YES=0
DOWNLOAD_URL=""
MODEL_DIR="/opt/models"
DEFAULT_MODEL_NAME="Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"
MODEL_PATH="${MODEL_DIR}/${DEFAULT_MODEL_NAME}"
LLAMA_DIR="/opt/llama.cpp"
SERVICE_USER="llama"

# Modelo sugerido (~1.1 GB) — cabe folgado nos 16 GB do Xeon.
# Nota: links de modelos podem mudar; se falhar, baixe manualmente (ver README).
SUGGESTED_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"

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
install_deps() {
  log_info "Instalando dependências do perfil xeon..."
  run "apt update" apt-get update
  run "Instalando pacotes base" apt-get install -y --no-install-recommends \
    build-essential cmake git ccache \
    libopenblas-dev libgomp1 \
    python3 python3-venv \
    curl ca-certificates pciutils util-linux
}

build_llama() {
  log_info "Compilando llama.cpp (Haswell-EP / AVX2)..."
  local flags=()
  [[ $DRY_RUN -eq 1 ]]    && flags+=(--dry-run)
  [[ $ASSUME_YES -eq 1 ]] && flags+=(--yes)
  run "Executando llama-build.sh" bash "${SCRIPT_DIR}/llama-build.sh" "${flags[@]+"${flags[@]}"}" --dir "$LLAMA_DIR"
}

apply_sysctl() {
  log_info "Aplicando sysctl do perfil xeon..."
  local f="/etc/sysctl.d/99-ai-tuning.conf"
  local src="${SCRIPT_DIR}/sysctl.conf"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] importaria ${src} → ${f}"
    return 0
  fi
  if [[ -f "$f" ]] && cmp -s "$src" "$f"; then
    log_info "sysctl já aplicado (idempotente)."
  else
    install -m 0644 "$src" "$f"
    run "Aplicando sysctl" sysctl --system
  fi
}

create_service_user() {
  if id "$SERVICE_USER" >/dev/null 2>&1; then
    log_info "Usuário '${SERVICE_USER}' já existe."
  else
    log_info "Criando usuário de serviço '${SERVICE_USER}' (sem login, sem shell)."
    run "Criando usuário" useradd --system --home-dir /var/lib/llama \
      --create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  fi
  run "Garantindo /var/lib/llama" install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 /var/lib/llama
  run "Garantindo ${MODEL_DIR}" install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "$MODEL_DIR"
}

install_service() {
  local unit_src="${SCRIPT_DIR}/ai-server.service"
  local unit_dst="/etc/systemd/system/ai-server.service"
  local env_dst="/etc/default/ai-server"

  write_env_file() {
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# Configuração do ai-server (gerado por profiles/xeon/install.sh)
MODEL_PATH=${MODEL_PATH}
LLAMA_THREADS=$(nproc --all 2>/dev/null || echo 24)
LLAMA_CTX=4096
EOF
    if [[ -f "$env_dst" ]] && cmp -s "$tmp" "$env_dst"; then
      log_info "EnvironmentFile já atualizado (idempotente)."; rm -f "$tmp"; return 0
    fi
    run "Escrevendo ${env_dst}" install -m 0644 "$tmp" "$env_dst"
    rm -f "$tmp"
  }

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] instalaria ${unit_src} → ${unit_dst}"
    log_info "[dry-run] escreveria ${env_dst}"
    return 0
  fi

  install -m 0644 "$unit_src" "$unit_dst"
  write_env_file
  run "Recarregando systemd" systemctl daemon-reload
  run "Habilitando ai-server" systemctl enable ai-server.service
  log_ok "Serviço ai-server instalado. Inicie com: sudo systemctl start ai-server"
}

download_model() {
  local url="$1"
  log_info "Baixando modelo: ${url}"
  log_info "Destino: ${MODEL_PATH}"
  if [[ -f "$MODEL_PATH" ]]; then
    log_info "Modelo já existe (idempotente): ${MODEL_PATH}"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] curl -L -o ${MODEL_PATH} ${url}"
    return 0
  fi
  if curl -fL --retry 3 -o "${MODEL_PATH}.part" "$url"; then
    mv "${MODEL_PATH}.part" "$MODEL_PATH"
    chown "$SERVICE_USER":"$SERVICE_USER" "$MODEL_PATH" 2>/dev/null || true
    log_ok "Modelo baixado: ${MODEL_PATH}"
  else
    rm -f "${MODEL_PATH}.part"
    log_error "Falha ao baixar o modelo. Baixe manualmente e ajuste MODEL_PATH em ${env_dst:-/etc/default/ai-server}."
    log_error "Ver docs/TROUBLESHOOTING.md → 'Modelo não carrega / OOM'."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)        DRY_RUN=1; shift ;;
      --yes)            ASSUME_YES=1; shift ;;
      --download-model) [[ $# -ge 2 ]] || { log_error "--download-model exige URL"; exit 2; }; DOWNLOAD_URL="$2"; shift 2 ;;
      --model-path)     [[ $# -ge 2 ]] || { log_error "--model-path exige caminho"; exit 2; }; MODEL_PATH="$2"; shift 2 ;;
      --auto-model)     DOWNLOAD_URL="${SUGGESTED_MODEL_URL}"; shift ;;
      -h|--help)
        echo "Uso: $0 [--dry-run] [--yes] [--download-model URL | --auto-model] [--model-path CAMINHO]"
        exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  log_info "=== install.sh (perfil xeon · servidor de IA em CPU) ==="
  log_warn "Xeon E5-2678 v3: 12c/24t, AVX2 apenas (SEM AVX-512)."
  log_warn "16 GB de RAM: modelos acima de ~7B Q4 não caberão."

  install_deps
  build_llama
  apply_sysctl
  create_service_user
  install_service

  if [[ -n "$DOWNLOAD_URL" ]]; then
    download_model "$DOWNLOAD_URL"
  else
    log_info "Nenhum modelo solicitado. Use --auto-model para baixar o Qwen2.5-Coder-1.5B (~1.1 GB)."
    log_info "Modelo esperado em MODEL_PATH: ${MODEL_PATH}"
  fi

  log_ok "install.sh (xeon) concluído."
  log_info "Próximos passos:"
  log_info "  1. (Opcional) sudo bash ${REPO_ROOT}/profiles/xeon/install.sh --auto-model --yes"
  log_info "  2. sudo systemctl start ai-server && curl -s http://127.0.0.1:8080/health"
  log_info "  3. python3 ${SCRIPT_DIR}/shell-ia.py"
  log_info "  4. Reinicie se o kernel-tuning alterou a cmdline do kernel."
}

main "$@"
