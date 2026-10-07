#!/usr/bin/env bash
#
# common/hugepages.sh — Transparent Huge Pages e huge pages estáticas
# -----------------------------------------------------------------------------
# Huge pages reduzem TLB misses no acesso aos pesos do modelo (o gargalo real
# de LLM em CPU é memória, não FLOPs). Este script:
#   1. Configura Transparent Huge Pages (THP) para 'always' (ou 'madvise').
#   2. Opcionalmente reserva huge pages estáticas (vm.nr_hugepages).
#   3. Persiste a configuração via /etc/sysctl.d e um serviço systemd.
#
# Uso:
#   sudo bash common/hugepages.sh [--dry-run] [--yes] [--mode always|madvise]
#
# Idempotente.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
THP_MODE="always"                 # always | madvise | never
RESERVE_HUGEPAGES=0               # 1 = reservar pool estático
HUGEPAGE_SIZE_KB=2048             # 2 MiB
HUGEPAGE_POOL_MB=4096             # alvo do pool estático, em MiB

readonly THP_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
readonly SYSCTL_FILE="/etc/sysctl.d/99-ai-hugepages.conf"
readonly UNIT_FILE="/etc/systemd/system/ai-hugepages.service"

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
# Transparent Huge Pages
# ---------------------------------------------------------------------------
configure_thp() {
  if [[ ! -f "$THP_ENABLED" ]]; then
    log_warn "${THP_ENABLED} não encontrado: THP indisponível neste kernel/sistema."
    return 0
  fi

  local current
  current="$(sed -E 's/.*\[([a-z]+)\].*/\1/' "$THP_ENABLED")"
  if [[ "$current" == "$THP_MODE" ]]; then
    log_info "THP já está em '${THP_MODE}' (idempotente)."
    return 0
  fi

  log_info "Configurando THP: '${current}' → '${THP_MODE}'."
  case "$THP_MODE" in
    always)  log_info "THP 'always': kernel usa 2 MiB automaticamente (menos TLB misses)." ;;
    madvise) log_info "THP 'madvise': só onde o processo pedir MADV_HUGEPAGE (mais conservador)." ;;
    never)   log_warn "THP 'never': desabilita huge pages transparentes (não recomendado para LLM)." ;;
    *) log_error "Modo THP inválido: ${THP_MODE}"; return 1 ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] echo ${THP_MODE} > ${THP_ENABLED}"
  else
    echo "$THP_MODE" > "$THP_ENABLED" 2>/dev/null || log_warn "Falha ao escrever THP (pode ser read-only em alguns kernels)."
  fi
}

# Persistência do THP via systemd (o sysfs não persiste entre reboots).
persist_thp() {
  write_file_if_changed "$UNIT_FILE" <<EOF
[Unit]
Description=ai-cpu-os: Transparent Huge Pages em ${THP_MODE}
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Aplica o modo THP desejado a cada boot.
ExecStart=/bin/sh -c 'echo ${THP_MODE} > ${THP_ENABLED}'

[Install]
WantedBy=multi-user.target
EOF

  if [[ $DRY_RUN -eq 0 && -f "$UNIT_FILE" ]]; then
    run "Recarregando systemd" systemctl daemon-reload
    run "Habilitando ai-hugepages.service" systemctl enable ai-hugepages.service
    run "Iniciando ai-hugepages.service" systemctl start ai-hugepages.service || true
  fi
}

# ---------------------------------------------------------------------------
# Huge pages estáticas (pool)
# ---------------------------------------------------------------------------
configure_static_pool() {
  local pages=$(( HUGEPAGE_POOL_MB * 1024 / HUGEPAGE_SIZE_KB ))

  if [[ -f /sys/kernel/mm/hugepages/hugepages-${HUGEPAGE_SIZE_KB}kB/nr_hugepages ]]; then
    : # suportado
  else
    log_warn "Huge pages de ${HUGEPAGE_SIZE_KB}kB não suportadas neste sistema; pulando pool estático."
    return 0
  fi

  log_info "Pool estático alvo: ${HUGEPAGE_POOL_MB} MiB (~${pages} páginas de ${HUGEPAGE_SIZE_KB}kB)."
  log_warn "Memória reservada para huge pages fica INDISPONÍVEL para outros processos."

  if ! confirm "Reservar ${HUGEPAGE_POOL_MB} MiB como huge pages estáticas?"; then
    log_warn "Pool estático não configurado."
    return 0
  fi

  write_file_if_changed "$SYSCTL_FILE" <<EOF
# /etc/sysctl.d/99-ai-hugepages.conf
# Gerado por ai-cpu-os/common/hugepages.sh — NÃO EDITAR À MÃO.
# Reserva um pool de páginas de ${HUGEPAGE_SIZE_KB}kB (${HUGEPAGE_POOL_MB} MiB).
# Nota: em alguns kernels o parâmetro é vm/nr_hugepages (sysctl vm.nr_hugepages).
vm.nr_hugepages = ${pages}
EOF

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] echo ${pages} > /proc/sys/vm/nr_hugepages"
  else
    echo "$pages" > /proc/sys/vm/nr_hugepages 2>/dev/null || log_warn "Falha ao aplicar nr_hugepages em runtime."
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
      --mode)    [[ $# -ge 2 ]] || { log_error "--mode exige valor"; exit 2; }; THP_MODE="$2"; shift 2 ;;
      --static|--reserve) RESERVE_HUGEPAGES=1; shift ;;
      -h|--help) echo "Uso: $0 [--dry-run] [--yes] [--mode always|madvise|never] [--static]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Requer root. Use: sudo bash $0"
    exit 1
  fi

  log_info "=== hugepages.sh: configurando huge pages ==="
  configure_thp
  persist_thp
  if [[ $RESERVE_HUGEPAGES -eq 1 ]]; then
    configure_static_pool
  else
    log_info "Pool estático não solicitado (use --static para reservar)."
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    log_info "Estado atual de huge pages:"
    grep -i Huge /proc/meminfo | sed 's/^/    | /' || true
  fi
  log_ok "hugepages.sh concluído."
}

main "$@"
