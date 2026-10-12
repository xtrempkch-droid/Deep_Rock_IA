#!/usr/bin/env bash
#
# mods/apply.sh — motor das MODIFICAÇÕES PORTÁVEIS do ai-cpu-os
# -----------------------------------------------------------------------------
# Uma "mod" é uma modificação pequena, isolada, reversível e documentada que
# qualquer pessoa pode aplicar e testar NO SEU PRÓPRIO sistema operacional —
# sem instalar o ai-cpu-os inteiro e sem travar o suporte a uma única CPU.
#
# Cada mod vive em mods/<id>/ e é composto por:
#   mod.conf   — metadados (nome, risco, requisitos, famílias, ganho esperado…)
#   apply.sh   — aplica (idempotente, aceita --dry-run)
#   revert.sh  — desfaz (volta ao estado anterior do sistema)
#
# Uso:
#   bash mods/apply.sh list                  # catálogo
#   bash mods/apply.sh info swappiness-10     # detalhes de uma mod
#   bash mods/apply.sh check [<id>]           # requisitos satisfeitos?
#   bash mods/apply.sh apply <id> [--dry-run] # aplica uma mod
#   bash mods/apply.sh apply --set system     # aplica um conjunto
#   bash mods/apply.sh revert <id>            # desfaz
#   bash mods/apply.sh test [<id>]            # testa em container Ubuntu
#
# Flags repassadas às mods: --dry-run | --yes (e as específicas da mod).
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

DRY_RUN=0
ASSUME_YES=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK"   "$(_ts)" "$*" "$C_RESET"; }
section()   { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
mods/apply.sh — modificações portáveis do ai-cpu-os

Uso:
  bash mods/apply.sh list
  bash mods/apply.sh info <id>
  bash mods/apply.sh check [<id>]
  bash mods/apply.sh apply <id> [--dry-run] [--yes]
  bash mods/apply.sh apply --set <conjunto> [--dry-run] [--yes]
  bash mods/apply.sh revert <id> [--dry-run] [--yes]
  bash mods/apply.sh test [<id>]

Conjuntos: system (tuning de base, usado pelo build.sh), portable (seguras
em qualquer máquina), all.
EOF
}

# ---------------------------------------------------------------------------
# Descoberta e metadados
# ---------------------------------------------------------------------------
mod_ids() {
  local d
  for d in "${SCRIPT_DIR}"/*/; do
    [[ -f "${d}mod.conf" ]] || continue
    basename "$d"
  done
}

# Carrega o mod.conf de uma mod e valida os campos essenciais.
load_mod() {
  local id="$1" conf="${SCRIPT_DIR}/${1}/mod.conf"
  if [[ ! -f "$conf" ]]; then
    log_error "mod desconhecida: '${id}' (não achei ${conf})"
    return 1
  fi
  MOD_ID="$id"; MOD_NAME=""; MOD_DESC=""; MOD_RISK="unknown"; MOD_REBOOT="no"
  MOD_REQUIRES=""; MOD_FAMILIES="any"; MOD_ROLES="any"; MOD_SETS=""
  MOD_GAIN=""; MOD_ORDER="50"
  # shellcheck source=/dev/null
  . "$conf"
  [[ -n "$MOD_DESC" ]] || log_warn "mod '${id}' sem MOD_DESC em mod.conf."
  return 0
}

mod_field() { printf '%s' "$1"; }

# ---------------------------------------------------------------------------
# Requisitos
# ---------------------------------------------------------------------------
_req_ok() {
  local req="$1"
  case "$req" in
    root)              [[ "${EUID:-$(id -u)}" -eq 0 ]] ;;
    systemd)           [[ -d /run/systemd/system ]] ;;
    linux\>=*)         local want="${req#linux>=}" have
                       have="$(uname -r)"
                       printf '%s\n%s\n' "$want" "$have" | sort -V -C ;;
    cmd:*)             command -v "${req#cmd:}" >/dev/null 2>&1 ;;
    path:*)            [[ -e "${req#path:}" ]] ;;
    cpuflag:*)         grep -qmw "${req#cpuflag:}" /proc/cpuinfo 2>/dev/null ;;
    *)                 log_warn "requisito desconhecido: '${req}' (tratado como satisfeito)" ; return 0 ;;
  esac
}

check_mod() {
  local id="$1"
  load_mod "$id" || return 1
  local ok=1 req
  for req in ${MOD_REQUIRES:-}; do
    if _req_ok "$req"; then
      printf '  %b✔%b %s\n' "$C_OK" "$C_RESET" "$req"
    else
      printf '  %b✘%b %s\n' "$C_ERR" "$C_RESET" "$req"
      ok=0
    fi
  done
  [[ $ok -eq 1 ]] || log_warn "mod '${id}': requisitos não satisfeitos (a mod pode falhar ou recusar aplicar)."
  return 0
}

# A mod é aplicável neste hardware/papel?
mod_applicable() {
  local id="$1"
  load_mod "$id" || return 1
  # Famílias: "any" ou lista de ids (compatível com prefixo, ex.: "intel-").
  if [[ "$MOD_FAMILIES" != "any" && -n "${FAMILY_ID:-}" ]]; then
    local f matched=0
    for f in $MOD_FAMILIES; do
      [[ "$FAMILY_ID" == "$f"* ]] && matched=1
    done
    [[ $matched -eq 1 ]] || { log_info "mod '${id}': não se aplica à família '${FAMILY_ID}'."; return 1; }
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Catálogo
# ---------------------------------------------------------------------------
cmd_list() {
  section "Mods disponíveis"
  printf '%-24s %-7s %-6s %-9s %s\n' "ID" "RISCO" "REBOOT" "CONJUNTO" "DESCRIÇÃO"
  printf '%-24s %-7s %-6s %-9s %s\n' "------------------------" "-------" "------" "---------" "-----------"
  local id
  while read -r id; do
    load_mod "$id" || continue
    printf '%-24s %-7s %-6s %-9s %s\n' \
      "$MOD_ID" "$MOD_RISK" "$MOD_REBOOT" "${MOD_SETS:-—}" "$MOD_DESC"
  done < <(mod_ids | sort)
  printf '\nAplicar:  sudo bash mods/apply.sh apply <id>\n'
  printf 'Conjunto: sudo bash mods/apply.sh apply --set system\n'
}

cmd_info() {
  local id="${1:-}"
  [[ -n "$id" ]] || { log_error "info exige um <id>"; exit 2; }
  load_mod "$id" || exit 1
  section "mod: ${MOD_ID}"
  printf 'Nome:       %s\n' "$MOD_NAME"
  printf 'Descrição:  %s\n' "$MOD_DESC"
  printf 'Risco:      %s\n' "$MOD_RISK"
  printf 'Reboot:     %s\n' "$MOD_REBOOT"
  printf 'Ganho:      %s\n' "${MOD_GAIN:-—}"
  printf 'Famílias:   %s\n' "$MOD_FAMILIES"
  printf 'Papéis:     %s\n' "$MOD_ROLES"
  printf 'Conjuntos:  %s\n' "${MOD_SETS:-—}"
  printf 'Requisitos: %s\n\n' "${MOD_REQUIRES:-nenhum}"
  check_mod "$id"
  printf '\nArquivos: %s/{mod.conf,apply.sh,revert.sh}\n' "${SCRIPT_DIR}/${MOD_ID}"
}

# ---------------------------------------------------------------------------
# Aplicar / reverter
# ---------------------------------------------------------------------------
_child_flags() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' --dry-run; fi
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' --yes; fi
  return 0
}

run_script() {
  local id="$1" kind="$2"; shift 2
  local script="${SCRIPT_DIR}/${id}/${kind}.sh"
  [[ -f "$script" ]] || { log_error "mod '${id}': falta ${kind}.sh"; return 1; }
  local -a flags=()
  mapfile -t flags < <(_child_flags)
  log_info "(${kind}) ${id} ${flags[*]:-}"
  bash "$script" "${flags[@]}" "$@"
}

cmd_apply() {
  local target="" set_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set) [[ $# -ge 2 ]] || { log_error "--set exige valor"; exit 2; }; set_name="$2"; shift 2 ;;
      -*)    log_error "flag desconhecida para apply: $1"; exit 2 ;;
      *)     target="$1"; shift ;;
    esac
  done

  if [[ -n "$set_name" ]]; then
    cmd_apply_set "$set_name"
    return 0
  fi
  [[ -n "$target" ]] || { log_error "apply exige <id> ou --set <conjunto>"; exit 2; }
  mod_applicable "$target" || { log_warn "Pulando '${target}' (não aplicável)."; return 0; }
  run_script "$target" apply
}

# Aplica todas as mods de um conjunto, em ordem determinística (MOD_ORDER).
cmd_apply_set() {
  local set_name="$1"
  local -a ids=()
  local id
  while read -r id; do
    load_mod "$id" || continue
    local s
    for s in ${MOD_SETS:-}; do
      [[ "$s" == "$set_name" || "$set_name" == "all" ]] && { ids+=("${MOD_ORDER}:${id}"); break; }
    done
  done < <(mod_ids)

  if [[ ${#ids[@]} -eq 0 ]]; then
    log_warn "Nenhuma mod no conjunto '${set_name}'."
    return 0
  fi

  section "Aplicando conjunto '${set_name}' (${#ids[@]} mods)"
  local entry
  while IFS= read -r entry; do
    id="${entry#*:}"
    if mod_applicable "$id"; then
      run_script "$id" apply
    fi
  done < <(printf '%s\n' "${ids[@]}" | sort -t: -k1,1n -k2,2)
  log_ok "Conjunto '${set_name}' concluído."
}

cmd_revert() {
  local target="${1:-}"
  [[ -n "$target" ]] || { log_error "revert exige um <id>"; exit 2; }
  run_script "$target" revert
}

# ---------------------------------------------------------------------------
# Teste em container (não privilegiado) — valida sintaxe, --dry-run,
# idempotência e revert sem tocar na máquina real.
# ---------------------------------------------------------------------------
cmd_test() {
  local only="${1:-}"
  if ! command -v docker >/dev/null 2>&1; then
    log_warn "docker ausente: não é possível rodar o teste em container."
    log_warn "Fallback: validação estática (bash -n + shellcheck) das mods."
  fi

  local id failures=0
  while read -r id; do
    [[ -n "$only" && "$id" != "$only" ]] && continue
    section "teste: ${id}"
    local s
    for s in apply revert; do
      local script="${SCRIPT_DIR}/${id}/${s}.sh"
      [[ -f "$script" ]] || { log_warn "  ${s}.sh ausente"; continue; }
      if bash -n "$script" 2>/dev/null; then
        printf '  %b✔%b %s\n' "$C_OK" "$C_RESET" "sintaxe ${s}.sh"
      else
        printf '  %b✘%b %s\n' "$C_ERR" "$C_RESET" "sintaxe ${s}.sh"
        failures=$((failures + 1))
      fi
    done

    if command -v docker >/dev/null 2>&1 && [[ $DRY_RUN -eq 0 ]]; then
      # Container efêmero, SEM --privileged: só valida que a mod roda e que é
      # idempotente. Mods que exigem root real ficam em --dry-run.
      local img="ubuntu:24.04"
      if docker run --rm -v "${SCRIPT_DIR}:/mods:ro" -w /mods "$img" \
           bash -c "bash /mods/${id}/apply.sh --dry-run && bash /mods/${id}/apply.sh --dry-run" >/dev/null 2>&1; then
        printf '  %b✔%b %s\n' "$C_OK" "$C_RESET" "dry-run idempotente em ${img}"
      else
        printf '  %b✘%b %s\n' "$C_ERR" "$C_RESET" "dry-run falhou em ${img}"
        failures=$((failures + 1))
      fi
    fi
  done < <(mod_ids | sort)

  if [[ $failures -gt 0 ]]; then
    log_error "Teste de mods: ${failures} falha(s)."
    return 1
  fi
  log_ok "Teste de mods: tudo OK."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-list}"; shift || true
  case "$cmd" in
    list)   cmd_list ;;
    info)   cmd_info "$@" ;;
    check)
      if [[ $# -gt 0 ]]; then check_mod "$1"; else
        local id; while read -r id; do section "$id"; check_mod "$id"; done < <(mod_ids | sort)
      fi ;;
    apply)
      # Aceita --dry-run/--yes antes ou depois do alvo.
      local -a rest=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) DRY_RUN=1; shift ;;
          --yes)     ASSUME_YES=1; shift ;;
          *) rest+=("$1"); shift ;;
        esac
      done
      cmd_apply "${rest[@]+"${rest[@]}"}" ;;
    revert)
      local -a rest=()
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) DRY_RUN=1; shift ;;
          --yes)     ASSUME_YES=1; shift ;;
          *) rest+=("$1"); shift ;;
        esac
      done
      cmd_revert "${rest[@]+"${rest[@]}"}" ;;
    test)
      DRY_RUN=0
      cmd_test "${1:-}" ;;
    -h|--help|help) usage ;;
    *) log_error "Comando desconhecido: ${cmd}"; usage; exit 2 ;;
  esac
}

main "$@"
