#!/usr/bin/env bash
#
# mods/governor/revert.sh — desfaz a mod governor
# -----------------------------------------------------------------------------
# Remove o serviço, devolve o governor ao padrão típico da distro (schedutil,
# com fallback para ondemand/powersave) e reabilita o intel_pstate passivo se
# ele tiver sido desligado.
#
# Uso: sudo bash revert.sh [--dry-run] [--yes]
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0; ASSUME_YES=0
readonly SERVICE="/etc/systemd/system/ai-cpu-governor.service"

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

log_info "=== revert: governor ==="

# 1) Serviço
if [[ -f "$SERVICE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] desabilitaria/removeria ${SERVICE}"
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl disable --now ai-cpu-governor.service >/dev/null 2>&1 || log_warn "Falha ao desabilitar ai-cpu-governor.service."
    fi
    rm -f "$SERVICE"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Serviço ai-cpu-governor removido."
  fi
else
  log_info "Nada a fazer: ${SERVICE} não existe (idempotente)."
fi

# 2) Governor de volta ao padrão da distro
target=""
for cand in schedutil ondemand powersave; do
  if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors ]]; then
    if grep -qw "$cand" /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; then
      target="$cand"; break
    fi
  fi
done

if [[ -z "$target" ]]; then
  log_info "Sem cpufreq disponível (comum em VM): nada a reverter."
elif [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] definiria governor='${target}' em todas as CPUs"
else
  if confirm "Definir governor='${target}' em todas as CPUs?"; then
    local_fail=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      [[ -w "$g" ]] || { local_fail=1; continue; }
      echo "$target" > "$g" 2>/dev/null || local_fail=1
    done
    if [[ $local_fail -eq 0 ]]; then
      log_ok "Governor='${target}' aplicado. (Voltará ao padrão do kernel no reboot.)"
    else
      log_warn "Alguns CPUs não aceitaram a mudança; o reboot restaura o padrão."
    fi
  fi
fi

# 3) intel_pstate: se ficou em 'passive', devolver ao padrão
if [[ -w /sys/devices/system/cpu/intel_pstate/status ]]; then
  if [[ "$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo '')" == "passive" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] devolveria intel_pstate para 'active'"
    elif confirm "Devolver intel_pstate para 'active'?"; then
      echo active > /sys/devices/system/cpu/intel_pstate/status 2>/dev/null \
        && log_ok "intel_pstate=active." || log_warn "Não consegui alterar intel_pstate."
    fi
  fi
fi

log_ok "revert: governor concluído."
