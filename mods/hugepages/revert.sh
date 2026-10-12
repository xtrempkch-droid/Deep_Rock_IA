#!/usr/bin/env bash
#
# mods/hugepages/revert.sh — desfaz a mod hugepages
# -----------------------------------------------------------------------------
# Volta THP para 'madvise' (padrão do kernel) e libera as huge pages estáticas.
# Uso: sudo bash revert.sh [--dry-run] [--yes]
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0; ASSUME_YES=0
readonly SYSCTL_FILE="/etc/sysctl.d/99-ai-hugepages.conf"
readonly SERVICE="/etc/systemd/system/ai-hugepages.service"
readonly THP="/sys/kernel/mm/transparent_hugepage/enabled"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
log_info()  { printf '%b[INFO ] %s%b\n' "$C_INFO" "$*" "$C_RESET"; }
log_warn()  { printf '%b[WARN ] %s%b\n' "$C_WARN" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[ERROR] %s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[OK   ] %s%b\n' "$C_OK" "$*" "$C_RESET"; }

confirm() {
  local p="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then return 0; fi
  local r; read -r -p "${p} [s/N] " r
  [[ "$r" =~ ^[sSyY]$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes)     ASSUME_YES=1; shift ;;
    -h|--help) echo "Uso: $0 [--dry-run] [--yes]"; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; exit 2 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
  log_error "Precisa de root. Use: sudo bash $0"
  exit 1
fi

log_info "=== revert: hugepages ==="

# 1) Serviço de boot
if [[ -f "$SERVICE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] desabilitaria/removeria ${SERVICE}"
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now ai-hugepages.service >/dev/null 2>&1 || log_warn "Falha ao desabilitar ai-hugepages.service."
    fi
    rm -f "$SERVICE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Serviço ai-hugepages removido."
  fi
else
  log_info "Nada a fazer: ${SERVICE} não existe (idempotente)."
fi

# 2) sysctl dedicado
if [[ -f "$SYSCTL_FILE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] removeria ${SYSCTL_FILE}"
  else
    rm -f "$SYSCTL_FILE"
    log_ok "Removido ${SYSCTL_FILE}."
    sysctl --system >/dev/null 2>&1 || log_warn "Rode 'sysctl --system' manualmente."
  fi
fi

# 3) THP de volta para madvise
if [[ -w "$THP" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] echo madvise > ${THP}"
  else
    if confirm "Voltar transparent_hugepage para 'madvise'?"; then
      echo madvise > "$THP" 2>/dev/null || log_warn "Não consegui escrever em ${THP}."
      log_ok "transparent_hugepage=$(cat "$THP" 2>/dev/null || echo '?')"
    fi
  fi
fi

# 4) Huge pages estáticas liberadas
if [[ -w /proc/sys/vm/nr_hugepages ]]; then
  local_nr="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)"
  if [[ "$local_nr" != "0" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] liberaria ${local_nr} huge pages estáticas (nr_hugepages=0)"
    else
      echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null \
        && log_ok "Huge pages estáticas liberadas (nr_hugepages=0)." \
        || log_warn "Huge pages em uso (algum processo as alocou); libere após encerrá-lo."
    fi
  fi
fi

log_ok "revert: hugepages concluído (THP voltou ao padrão da distro)."
