#!/usr/bin/env bash
#
# common/governor.sh — CPU governor 'performance' e C-states rasos
# -----------------------------------------------------------------------------
# Trava todos os núcleos na maior frequência e reduz a latência de wake-up,
# eliminando o jitter de escalonamento durante a inferência.
#
# Uso:
#   sudo bash common/governor.sh [--dry-run] [--yes] [--governor performance]
#
# Persistência: unit systemd aplicada no boot.
# Idempotente.
#
# ⚠️ AVISO: governor 'performance' aumenta consumo de energia e temperatura.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
GOVERNOR="performance"
readonly UNIT_FILE="/etc/systemd/system/ai-cpu-governor.service"

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

write_file_if_changed() {
  local path="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    log_info "Sem alterações em ${path} (idempotente)."; rm -f "$tmp"; return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] escreveria ${path}:"; sed 's/^/    | /' "$tmp"; rm -f "$tmp"; return 0
  fi
  run "Escrevendo ${path}" install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Aplicação imediata do governor
# ---------------------------------------------------------------------------
apply_governor() {
  if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    log_warn "cpufreq indisponível (driver ausente ou VM). Governor não aplicado."
    return 0
  fi

  local avail
  avail="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || true)"
  if [[ "$avail" != *"$GOVERNOR"* ]]; then
    log_warn "Governor '${GOVERNOR}' não disponível. Disponíveis: ${avail:-?}"
    log_warn "Em intel_pstate 'active', tente: cpupower frequency-set -g performance"
    return 0
  fi

  local cpu path current
  for path in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -f "$path" ]] || continue
    current="$(cat "$path" 2>/dev/null || echo '?')"
    if [[ "$current" == "$GOVERNOR" ]]; then
      continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] echo ${GOVERNOR} > ${path}"
    else
      echo "$GOVERNOR" > "$path" 2>/dev/null || log_warn "Falha ao escrever ${path}"
    fi
    cpu="$(basename "$(dirname "$(dirname "$path")")")"
    log_info "cpu ${cpu}: '${current}' → '${GOVERNOR}'"
  done
  log_ok "Governor '${GOVERNOR}' aplicado (ou já aplicado)."
}

# ---------------------------------------------------------------------------
# Persistência via systemd
# ---------------------------------------------------------------------------
persist_governor() {
  write_file_if_changed "$UNIT_FILE" <<EOF
[Unit]
Description=ai-cpu-os: CPU governor '${GOVERNOR}'
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Aplica o governor em todos os CPUs a cada boot.
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do [ -f "\$f" ] && echo ${GOVERNOR} > "\$f"; done'

[Install]
WantedBy=multi-user.target
EOF

  if [[ $DRY_RUN -eq 0 && -f "$UNIT_FILE" ]]; then
    run "Recarregando systemd" systemctl daemon-reload
    run "Habilitando ai-cpu-governor.service" systemctl enable ai-cpu-governor.service
  fi
}

# ---------------------------------------------------------------------------
# C-states: relatório (a aplicação é feita no kernel-tuning.sh / GRUB)
# ---------------------------------------------------------------------------
report_cstates() {
  if [[ -d /sys/devices/system/cpu/cpu0/cpuidle ]]; then
    log_info "C-states disponíveis em cpu0:"
    local s
    for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/name; do
      [[ -f "$s" ]] || continue
      log_info "    $(cat "$s")"
    done
    log_info "Para desativar C-states profundos: common/kernel-tuning.sh (cmdline + reboot)."
  else
    log_info "cpuidle não exposto (VM?) — C-states não gerenciados."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=1; shift ;;
      --yes)       ASSUME_YES=1; shift ;;
      --governor)  [[ $# -ge 2 ]] || { log_error "--governor exige valor"; exit 2; }; GOVERNOR="$2"; shift 2 ;;
      -h|--help)   echo "Uso: $0 [--dry-run] [--yes] [--governor performance|powersave|schedutil]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  log_info "=== governor.sh: configurando CPU governor ==="
  log_warn "Governor '${GOVERNOR}' aumenta consumo de energia e temperatura."

  apply_governor
  persist_governor
  report_cstates

  log_ok "governor.sh concluído."
}

main "$@"
