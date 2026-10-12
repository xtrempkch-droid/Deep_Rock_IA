#!/usr/bin/env bash
#
# mods/openblas-threads/revert.sh — remove o bloco de variáveis de ambiente
# Uso: sudo bash revert.sh [--dry-run] [--yes]
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
readonly ENV_FILE="/etc/environment"
readonly MARK_BEGIN="# >>> ai-cpu-os: openblas-threads >>>"
readonly MARK_END="# <<< ai-cpu-os: openblas-threads <<<"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
log_info()  { printf '%b[INFO ] %s%b\n' "$C_INFO" "$*" "$C_RESET"; }
log_warn()  { printf '%b[WARN ] %s%b\n' "$C_WARN" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[ERROR] %s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[OK   ] %s%b\n' "$C_OK" "$*" "$C_RESET"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes)     shift ;;  # aceito por compatibilidade: o revert não pede confirmação
    -h|--help) echo "Uso: $0 [--dry-run] [--yes]"; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; exit 2 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
  log_error "Precisa de root. Use: sudo bash $0"
  exit 1
fi

log_info "=== revert: openblas-threads ==="

if [[ ! -f "$ENV_FILE" ]] || ! grep -qF "$MARK_BEGIN" "$ENV_FILE" 2>/dev/null; then
  log_info "Nada a fazer: bloco não encontrado em ${ENV_FILE} (idempotente)."
  exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] removeria o bloco delimitado por '${MARK_BEGIN}' em ${ENV_FILE}"
  exit 0
fi

cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
# Remove do marcador de início até o de fim (inclusive), sem tocar no resto.
sed -i "\|${MARK_BEGIN}|,\|${MARK_END}|d" "$ENV_FILE"
# Colapsa linhas em branco duplicadas que o bloco possa ter deixado.
sed -i '/^$/{N;/^\n$/D}' "$ENV_FILE"

log_ok "Bloco removido de ${ENV_FILE}."
log_info "Reinicie os serviços de inferência para voltar ao comportamento anterior."
