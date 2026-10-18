#!/usr/bin/env bash
#
# mods/apt-sources/revert.sh — devolve as fontes do apt como estavam
# -----------------------------------------------------------------------------
# Restaura todo `<arquivo>.ai-cpu-os.bak` que o `apply.sh` criou e remove a
# lista oficial que ele gravou (se houver backup do original, o backup volta).
#
# ⚠️ Reverter pode DEVOLVER o apt quebrado (era o estado anterior). O script
# avisa disso e pede confirmação, salvo com --yes.
#
# Uso:
#   sudo bash mods/apt-sources/revert.sh
#   sudo bash mods/apt-sources/revert.sh --root /mnt/alvo --yes
#   sudo bash mods/apt-sources/revert.sh --dry-run
# -----------------------------------------------------------------------------

set -euo pipefail

TARGET_ROOT="/"
DRY_RUN=0
ASSUME_YES=0

log()   { printf '[apt-sources/revert] %s\n' "$*"; }
warn()  { printf '[apt-sources/revert] AVISO: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)     [[ $# -ge 2 ]] || { warn "--root exige um diretório"; exit 2; }
                TARGET_ROOT="${2%/}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          warn "opção desconhecida: $1"; exit 2 ;;
  esac
done

[[ -d "$TARGET_ROOT" ]] || { warn "diretório inexistente: $TARGET_ROOT"; exit 2; }
APT_DIR="${TARGET_ROOT%/}/etc/apt"
[[ -d "$APT_DIR" ]] || { warn "${APT_DIR} não existe."; exit 1; }

shopt -s nullglob
mapfile -t BACKUPS < <(printf '%s\n' "${APT_DIR}"/sources.list.ai-cpu-os.bak "${APT_DIR}"/sources.list.d/*.ai-cpu-os.bak 2>/dev/null)
shopt -u nullglob

if [[ ${#BACKUPS[@]} -eq 0 ]]; then
  log "nenhum backup encontrado: nada a reverter."
  exit 0
fi

log "serão restaurados ${#BACKUPS[@]} arquivo(s):"
printf '  %s\n' "${BACKUPS[@]}"

if [[ $DRY_RUN -eq 1 ]]; then
  log "[dry-run] nada foi alterado."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  warn "Isto devolve a configuração ANTERIOR — que pode ser a que deixou o apt quebrado."
  printf 'Continuar? [s/N] '
  read -r ans
  case "$ans" in s|S|y|Y) ;; *) log "cancelado."; exit 0 ;; esac
fi

for b in "${BACKUPS[@]}"; do
  orig="${b%.ai-cpu-os.bak}"
  cp -a "$b" "$orig"
  rm -f "$b"
  log "restaurado: ${orig}"
done

log "pronto. Rode 'apt-get update' para conferir."
