#!/usr/bin/env bash
#
# common/kernel-tuning.sh — Tuning de kernel/sysctl do ai-cpu-os
# -----------------------------------------------------------------------------
# Aplica /etc/sysctl.d/99-ai-tuning.conf, verifica io_uring e orienta o ajuste
# da cmdline do kernel (C-states profundos) para reduzir latência de memória e
# de wake-up durante a inferência.
#
# Uso:
#   sudo bash common/kernel-tuning.sh [--dry-run] [--yes]
#
# Idempotente: só escreve/reinicia quando necessário.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
readonly SYSCTL_FILE="/etc/sysctl.d/99-ai-tuning.conf"
readonly GRUB_FILE="/etc/default/grub"

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
    log_info "Sem alterações em ${path} (idempotente)."
    rm -f "$tmp"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] escreveria ${path}:"
    sed 's/^/    | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  run "Escrevendo ${path}" install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Detecção de socket único (para decidir numa_balancing)
# ---------------------------------------------------------------------------
is_single_socket() {
  local nodes=0
  if [[ -d /sys/devices/system/node ]]; then
    nodes="$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | wc -l || echo 0)"
  fi
  [[ "$nodes" -le 1 ]]
}

# ---------------------------------------------------------------------------
# Verificação de io_uring (kernel >= 5.1)
# ---------------------------------------------------------------------------
check_io_uring() {
  local krel major minor
  krel="$(uname -r)"
  major="${krel%%.*}"
  minor="$(cut -d. -f2 <<<"$krel")"
  minor="${minor%%[!0-9]*}"

  if [[ "$major" -gt 5 || ( "$major" -eq 5 && "$minor" -ge 1 ) ]]; then
    log_ok "io_uring disponível: kernel ${krel} (>= 5.1)."
    if [[ -e /proc/sys/kernel/io_uring_disabled ]]; then
      local dis
      dis="$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo 0)"
      log_info "kernel.io_uring_disabled=${dis} (0 = habilitado)."
    fi
  else
    log_warn "Kernel ${krel} < 5.1: io_uring pode não estar disponível."
  fi
}

# ---------------------------------------------------------------------------
# Configuração de C-states via cmdline (requer reboot)
# ---------------------------------------------------------------------------
configure_cstates() {
  local param="intel_idle.max_cstate=1"
  # Ryzen (AMD) usa acpi_idle/amd_pstate; o parâmetro intel_idle não se aplica.
  local vendor
  vendor="$(grep -m1 vendor_id /proc/cpuinfo | cut -d: -f2- | tr -d ' *' || true)"

  if [[ "$vendor" == *AMD* || "$vendor" == *AuthenticAMD* ]]; then
    param="processor.max_cstate=1"
    log_info "Fabricante AMD detectado: usando '${param}'."
  fi

  if [[ ! -f "$GRUB_FILE" ]]; then
    log_warn "${GRUB_FILE} não encontrado; ajuste a cmdline do kernel manualmente: ${param}"
    return 0
  fi

  if grep -q "${param}" "$GRUB_FILE" 2>/dev/null; then
    log_info "Cmdline já contém '${param}' (idempotente)."
  else
    log_warn "C-states profundos serão desativados via GRUB — REQUER REBOOT."
    log_warn "Parâmetro: ${param} (reduz latência de wake-up de ~100µs para ~1µs)."
    if confirm "Adicionar '${param}' a GRUB_CMDLINE_LINUX_DEFAULT?"; then
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[dry-run] adicionaria '${param}' em ${GRUB_FILE} e rodaria update-grub."
      else
        cp -a "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
        if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
          sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${param}\"|" "$GRUB_FILE"
        else
          printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$param" >> "$GRUB_FILE"
        fi
        log_ok "Backup criado e ${GRUB_FILE} atualizado."
        if command -v update-grub >/dev/null 2>&1; then
          run "Atualizando GRUB" update-grub
        else
          log_warn "update-grub não encontrado; rode-o manualmente antes de reiniciar."
        fi
      fi
    else
      log_warn "Cmdline do kernel não alterada."
    fi
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

  log_info "=== kernel-tuning.sh: aplicando sysctl de IA ==="

  # Decide numa_balancing conforme topologia.
  local numa_value="0"
  if is_single_socket; then
    log_info "Topologia: single-socket → kernel.numa_balancing=0 (remove overhead de balanceamento)."
  else
    numa_value="1"
    log_info "Topologia: multi-socket → mantendo kernel.numa_balancing=1."
  fi

  write_file_if_changed "$SYSCTL_FILE" <<EOF
# /etc/sysctl.d/99-ai-tuning.conf
# Gerado por ai-cpu-os/common/kernel-tuning.sh — NÃO EDITAR À MÃO.
# Ver docs/TUNING.md para a justificativa de cada valor.

# --- Memória ---
# Reduz paginação agressiva do modelo (evita swap durante inferência).
vm.swappiness = 10
# Mantém dentries/inodes em cache (menos I/O repetido).
vm.vfs_cache_pressure = 50
# Suaviza picos de escrita em disco (write stall).
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# --- NUMA ---
# Desligado apenas em single-socket (ver script); não adiciona valor com 1 nó.
kernel.numa_balancing = ${numa_value}

# --- Rede ---
# Buffers de socket maiores: llama-server (HTTP) e registry Docker.
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
EOF

  if [[ $DRY_RUN -eq 0 && -f "$SYSCTL_FILE" ]]; then
    run "Aplicando sysctl" sysctl --system
  else
    log_info "[dry-run] aplicaria sysctl --system"
  fi

  check_io_uring
  configure_cstates

  log_ok "kernel-tuning.sh concluído."
  log_warn "ALTERAÇÕES DE CMDLINE SÓ VALEM APÓS REBOOT. Rode 'sudo reboot' quando puder."
}

main "$@"
