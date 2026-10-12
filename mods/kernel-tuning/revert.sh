#!/usr/bin/env bash
#
# mods/kernel-tuning/revert.sh — desfaz a mod kernel-tuning
# -----------------------------------------------------------------------------
# Remove APENAS o que a mod adicionou, voltando ao comportamento padrão da
# distro: o arquivo sysctl dedicado e os parâmetros de C-state na cmdline.
# Backup do GRUB é feito antes de editar.
#
# Uso: sudo bash revert.sh [--dry-run] [--yes]
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0; ASSUME_YES=0
readonly SYSCTL_FILE="/etc/sysctl.d/99-ai-tuning.conf"
readonly GRUB_FILE="/etc/default/grub"
readonly REVERT_MARKER="# ai-cpu-os (kernel-tuning revert)"

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

log_info "=== revert: kernel-tuning ==="

# 1) sysctl dedicado
if [[ -f "$SYSCTL_FILE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] removeria ${SYSCTL_FILE}"
  else
    confirm "Remover ${SYSCTL_FILE}?" || { log_warn "Mantido."; }
    if [[ -f "$SYSCTL_FILE" ]]; then
      rm -f "$SYSCTL_FILE"
      log_ok "Removido ${SYSCTL_FILE} (o valor volta ao padrão da distro no reboot)."
      sysctl --system >/dev/null 2>&1 || log_warn "Rode 'sysctl --system' manualmente."
    fi
  fi
else
  log_info "Nada a fazer: ${SYSCTL_FILE} não existe (idempotente)."
fi

# 2) cmdline (C-states)
if [[ -f "$GRUB_FILE" ]] && grep -qE '(intel_idle|processor)\.max_cstate=' "$GRUB_FILE" 2>/dev/null; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] removeria 'intel_idle.max_cstate'/'processor.max_cstate' de ${GRUB_FILE}"
  else
    if confirm "Remover os parâmetros de C-state de ${GRUB_FILE}?"; then
      cp -a "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
      sed -i -E 's/([[:space:]]*)(intel_idle\.max_cstate=[^"[:space:]]*|processor\.max_cstate=[^"[:space:]]*)//g' "$GRUB_FILE"
      log_ok "Parâmetros removidos de ${GRUB_FILE}."
      if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null 2>&1 && log_ok "GRUB atualizado."
      else
        log_warn "update-grub não encontrado; rode-o manualmente."
      fi
      log_warn "A remoção dos C-states só vale após REBOOT."
    fi
  fi
else
  log_info "Nada a fazer: nenhum parâmetro de C-state na cmdline."
fi

log_ok "revert: kernel-tuning concluído. ${REVERT_MARKER}"
