#!/usr/bin/env bash
#
# mods/network/revert.sh — desfaz a rede persistente do ai-cpu-os
# -----------------------------------------------------------------------------
# Remove o que a mod `network` gravou e DEVOLVE o netplan do instalador/
# cloud-init que ela havia movido para *.ai-cpu-os.bak.
#
# ⚠️ Sem o netplan do instalador e sem o nosso, a máquina pode ficar SEM rede no
# próximo boot. Por isso o revert AVISA o que vai acontecer e, se encontrar um
# backup, restaura — em vez de deixar o sistema sem configuração nenhuma.
#
# Uso:
#   sudo bash revert.sh              # remove a config do ai-cpu-os
#   sudo bash revert.sh --root DIR   # em outro sistema (teste / disco montado)
#   sudo bash revert.sh --dry-run
# -----------------------------------------------------------------------------

set -euo pipefail

TARGET_ROOT="/"
DRY_RUN=0

readonly NETPLAN_NAME="99-ai-cpu-os.yaml"
readonly CLOUD_INIT_NAME="99-ai-cpu-os-disable-network.cfg"

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
    --root)    [[ $# -ge 2 ]] || { log_error "--root exige valor"; exit 2; }; TARGET_ROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes)     shift ;;   # aceito por compatibilidade: o revert não pede confirmação
    -h|--help) echo "Uso: $0 [--root DIR] [--dry-run] [--yes]"; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; exit 2 ;;
  esac
done

if [[ $DRY_RUN -eq 0 && "${EUID:-$(id -u)}" -ne 0 && "$TARGET_ROOT" == "/" ]]; then
  log_error "Precisa de root. Use: sudo bash $0"
  exit 1
fi

ROOT="${TARGET_ROOT%/}"
[[ -z "$ROOT" ]] && ROOT=""
NETPLAN_DIR="${ROOT}/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/${NETPLAN_NAME}"
CLOUD_FILE="${ROOT}/etc/cloud/cloud.cfg.d/${CLOUD_INIT_NAME}"

log_info "=== revert: network${ROOT:+ (root=${ROOT})} ==="

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] removeria ${NETPLAN_FILE} e ${CLOUD_FILE}"
  log_info "[dry-run] restauraria ${NETPLAN_DIR}/*.ai-cpu-os.bak"
  exit 0
fi

changed=0

if [[ -f "$NETPLAN_FILE" ]]; then
  rm -f "$NETPLAN_FILE"
  log_ok "removido ${NETPLAN_FILE}"
  changed=1
else
  log_info "${NETPLAN_FILE} não existe (idempotente)."
fi

if [[ -f "$CLOUD_FILE" ]]; then
  rm -f "$CLOUD_FILE"
  log_ok "removido ${CLOUD_FILE}"
  changed=1
fi

# Devolve o que a mod tirou do caminho.
shopt -s nullglob
restored=0
for f in "${NETPLAN_DIR}"/*.ai-cpu-os.bak; do
  orig="${f%.ai-cpu-os.bak}"
  mv "$f" "$orig"
  log_ok "restaurado $(basename "$orig")"
  restored=1
  changed=1
done
shopt -u nullglob

if [[ $restored -eq 0 && ! -f "$NETPLAN_FILE" ]]; then
  log_warn "Nenhum backup de netplan para restaurar e a config do ai-cpu-os saiu do lugar."
  log_warn "A máquina pode subir SEM rede. Se for o caso, crie manualmente:"
  log_warn "  ${NETPLAN_DIR}/99-rede.yaml  com  network: {version: 2, ethernets: {all-en: {match: {name: \"en*\"}, dhcp4: true}}}"
fi

if [[ $changed -eq 0 ]]; then
  log_info "Nada a fazer (idempotente)."
  exit 0
fi

if [[ -z "$ROOT" ]] && command -v netplan >/dev/null 2>&1; then
  if netplan apply; then
    log_ok "netplan apply: revert aplicado."
  else
    log_warn "netplan apply falhou; vale a partir do próximo boot."
  fi
fi

log_ok "mod network revertida."
