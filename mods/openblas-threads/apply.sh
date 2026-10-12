#!/usr/bin/env bash
#
# mods/openblas-threads/apply.sh — OpenBLAS com 1 thread
# -----------------------------------------------------------------------------
# Por quê: o llama.cpp paraleliza com `-t N` (threads do ggml). Se o OpenBLAS
# também abrir N threads por chamada, os dois competem pelos mesmos núcleos e o
# resultado é *menos* tokens/s no prompt processing e latência instável.
# Com OpenBLAS em 1 thread, a paralelização fica toda nas mãos do ggml.
#
# Risco baixo: são apenas variáveis de ambiente. Reversível (revert.sh) e não
# exige reboot — basta reiniciar o serviço.
#
# Uso: sudo bash apply.sh [--dry-run] [--yes]
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
    --yes)     shift ;;  # aceito por compatibilidade: esta mod não pede confirmação
    -h|--help) echo "Uso: $0 [--dry-run] [--yes]"; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; exit 2 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
  log_error "Precisa de root. Use: sudo bash $0"
  exit 1
fi

log_info "=== mod: openblas-threads ==="

if [[ ! -f "$ENV_FILE" ]]; then
  log_warn "${ENV_FILE} não existe; criando."
  [[ $DRY_RUN -eq 1 ]] || : > "$ENV_FILE"
fi

if grep -qF "$MARK_BEGIN" "$ENV_FILE" 2>/dev/null; then
  log_info "Bloco já presente em ${ENV_FILE} (idempotente). Nada a fazer."
  exit 0
fi

BLOCK="${MARK_BEGIN}
# OpenBLAS com 1 thread: a paralelização fica com o ggml (flag -t do llama.cpp).
OPENBLAS_NUM_THREADS=1
OMP_NUM_THREADS=1
${MARK_END}"

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] adicionaria a ${ENV_FILE}:"
  printf '%s\n' "$BLOCK" | sed 's/^/    /'
  exit 0
fi

cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%s)"
printf '\n%s\n' "$BLOCK" >> "$ENV_FILE"
log_ok "Bloco adicionado a ${ENV_FILE}."

log_warn "Variáveis de ambiente só valem para processos NOVOS e que leiam /etc/environment."
log_info "Para o serviço de inferência, garanta o mesmo em um drop-in do systemd:"
log_info "  systemctl edit ai-server   →  [Service] / Environment=OPENBLAS_NUM_THREADS=1"
log_ok "mod openblas-threads aplicada. Reinicie o serviço para valer."
