#!/usr/bin/env bash
#
# build.sh — Orquestrador principal do ai-cpu-os
# -----------------------------------------------------------------------------
# Transforma um Ubuntu/Debian minimal em um sistema otimizado para inferência
# de LLMs 100% em CPU. Separa dois conceitos que antes estavam misturados:
#
#   FAMÍLIA  = quem é o hardware  (intel-broadwell, amd-zen2, …)  → ISA/march
#   PAPEL    = para que serve     (inference | builder)           → o que instala
#
# Uso:
#   sudo ./build.sh                       # detecta família e papel, pergunta
#   sudo ./build.sh --role inference      # força o papel
#   sudo ./build.sh --family amd-zen2     # força a família
#   sudo ./build.sh --dry-run             # simula, não aplica
#   sudo ./build.sh --yes                 # não pede confirmação
#
# Regras de qualidade: set -euo pipefail, logs com timestamp e nível,
# idempotência, --dry-run, confirmação antes de ações sensíveis.
# -----------------------------------------------------------------------------

set -euo pipefail

# ---------------------------------------------------------------------------
# Constantes e caminhos
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MODS_DIR="${SCRIPT_DIR}/mods"
readonly ROLES_DIR="${SCRIPT_DIR}/roles"
readonly FAMILIES_DIR="${SCRIPT_DIR}/families"
readonly TESTS_DIR="${SCRIPT_DIR}/tests"
readonly LOG_FILE="/var/log/ai-cpu-os-build.log"

ROLE="auto"
FAMILY="auto"
DRY_RUN=0
ASSUME_YES=0
SKIP_TESTS=0
SKIP_MODS=0
# Modelo e fonte locais: repassados por AMBIENTE aos scripts de papel, porque
# `sudo` limpa o ambiente — sem estas flags não haveria como usá-los na mão.
AI_MODEL_FILE_SRC=""
AI_LLAMA_SOURCE_SRC=

# Cores (desativadas se não for TTY)
if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi

# ---------------------------------------------------------------------------
# Logging — timestamp + nível, e espelho em arquivo quando possível
# ---------------------------------------------------------------------------
_log() {
  local level="$1"; shift
  local color="" ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  case "$level" in
    INFO)  color="$C_INFO" ;;
    WARN)  color="$C_WARN" ;;
    ERROR) color="$C_ERR"  ;;
    OK)    color="$C_OK"   ;;
  esac
  printf '%b[%s] [%-5s] %s%b\n' "$color" "$ts" "$level" "$*" "$C_RESET"
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@" >&2; }
log_ok()    { _log OK    "$@"; }

# Inicia espelhamento em arquivo (best-effort; requer permissão de escrita).
start_file_log() {
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  if touch "$LOG_FILE" 2>/dev/null; then
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Log espelhado em ${LOG_FILE}"
  else
    log_warn "Não foi possível escrever em ${LOG_FILE} (sem permissão). Continuando apenas no stdout."
  fi
}

# Executa um comando, respeitando --dry-run.
# Uso: run "descrição" cmd arg1 arg2 ...
run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] ${desc}: $*"
    return 0
  fi
  log_info "${desc}: $*"
  "$@"
}

# Confirmação interativa (pulada com --yes ou --dry-run).
confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then
    return 0
  fi
  local reply
  read -r -p "${prompt} [s/N] " reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

# ---------------------------------------------------------------------------
# Uso / ajuda
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
build.sh — ai-cpu-os

Uso:
  sudo ./build.sh [opções]

Opções:
  --role <auto|inference|builder>   Papel da máquina (padrão: auto).
  --family <auto|ID>                Família de CPU (ex.: intel-broadwell).
  --dry-run                         Simula, sem alterar o sistema.
  --yes                             Não pede confirmação (automação/CI).
  --skip-mods                       Não aplica as mods do conjunto 'system'.
  --skip-tests                      Não roda o smoke-test ao final.
  --list-families                   Lista as famílias suportadas e sai.
  -h, --help                        Mostra esta ajuda.

Variáveis de ambiente:
  AI_ROLE      Alternativa a --role.
  AI_FAMILY    Alternativa a --family.
  AI_PROFILE   Nome antigo de AI_ROLE (compatibilidade: xeon→inference,
               ryzen→builder).

Exemplos:
  sudo ./build.sh
  sudo ./build.sh --role inference --family intel-broadwell
  sudo ./build.sh --dry-run
  sudo ./build.sh --role builder --yes
EOF
}

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        [[ $# -ge 2 ]] || { log_error "--role exige um valor."; exit 2; }
        ROLE="$2"; shift 2 ;;
      --family)
        [[ $# -ge 2 ]] || { log_error "--family exige um valor."; exit 2; }
        FAMILY="$2"; shift 2 ;;
      # Compatibilidade com a interface antiga (perfil).
      --profile)
        [[ $# -ge 2 ]] || { log_error "--profile exige um valor."; exit 2; }
        log_warn "--profile está obsoleto; use --role (xeon→inference, ryzen→builder)."
        case "$2" in
          xeon)  ROLE="inference" ;;
          ryzen) ROLE="builder" ;;
          *)     ROLE="$2" ;;
        esac
        shift 2 ;;
      --dry-run)     DRY_RUN=1; shift ;;
      --yes)         ASSUME_YES=1; shift ;;
      --skip-mods)   SKIP_MODS=1; shift ;;
      --skip-common) SKIP_MODS=1; shift ;;
      --skip-tests)  SKIP_TESTS=1; shift ;;
      --model-file)  [[ $# -ge 2 ]] || { log_error "--model-file exige caminho"; exit 2; }; AI_MODEL_FILE_SRC="$2"; shift 2 ;;
      --llama-source) [[ $# -ge 2 ]] || { log_error "--llama-source exige caminho"; exit 2; }; AI_LLAMA_SOURCE_SRC="$2"; shift 2 ;;
      --list-families) list_families; exit 0 ;;
      -h|--help)     usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  # Variáveis de ambiente como fallback (--role/--family têm precedência).
  if [[ "$ROLE" == "auto" ]]; then
    if [[ -n "${AI_ROLE:-}" ]]; then
      ROLE="$AI_ROLE"
    elif [[ -n "${AI_PROFILE:-}" ]]; then
      case "$AI_PROFILE" in
        xeon)  ROLE="inference" ;;
        ryzen) ROLE="builder" ;;
        *)     ROLE="$AI_PROFILE" ;;
      esac
    fi
  fi
  if [[ "$FAMILY" == "auto" && -n "${AI_FAMILY:-}" ]]; then
    FAMILY="$AI_FAMILY"
  fi

  case "$ROLE" in
    auto|inference|builder) ;;
    *) log_error "Papel inválido: '${ROLE}'. Use auto, inference ou builder."; exit 2 ;;
  esac
}

# Lista as famílias suportadas (delegado a families/resolve.sh).
list_families() {
  local r="${FAMILIES_DIR}/resolve.sh"
  if [[ ! -f "$r" ]]; then
    log_error "families/resolve.sh não encontrado."
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$r"
  section_pretty() { printf '\n== %s ==\n' "$1"; }
  section_pretty "Famílias suportadas"
  local id
  for id in $(families_available); do
    load_family "$id"
    printf '  %-22s %-12s %s\n' "$id" "${FAMILY_AVX512_POLICY:-?}" "${FAMILY_NAME:-}"
  done
  printf '\nUse: sudo ./build.sh --family <id>\n'
}

# ---------------------------------------------------------------------------
# Pré-checagens
# ---------------------------------------------------------------------------
check_root() {
  # --dry-run pode rodar sem root (apenas inspeção), mas avisamos.
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_warn "Rodando --dry-run sem root: a detecção de RAM/canais pode ser incompleta."
    else
      log_error "Este script precisa de root. Use: sudo ./build.sh ..."
      exit 1
    fi
  fi
}

check_os() {
  local id="" ver=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"; ver="${VERSION_ID:-}"
  fi
  case "$id" in
    debian)
      if [[ "${ver%%.*}" -lt 12 ]]; then
        log_error "Debian ${ver} detectado. Requerido Debian 12+ (Bookworm)."
        exit 1
      fi
      ;;
    ubuntu)
      # Compara "22.04" ou superior de forma simples
      if [[ "${ver%%.*}" -lt 22 ]]; then
        log_error "Ubuntu ${ver} detectado. Requerido Ubuntu 22.04+."
        exit 1
      fi
      ;;
    "")
      log_warn "Não foi possível ler /etc/os-release; prosseguindo por sua conta e risco."
      ;;
    *)
      log_warn "Distro '${id}' não é oficialmente suportada (Debian/Ubuntu). Prosseguindo, mas pode falhar."
      ;;
  esac
  log_ok "Sistema operacional aceito: ${id:-desconhecido} ${ver:-}"
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    log_error "Arquivo obrigatório não encontrado: $f"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Detecção de família e papel via detect-hardware.sh
# ---------------------------------------------------------------------------
resolve_role() {
  local detector="${SCRIPT_DIR}/detect-hardware.sh"
  require_file "$detector"

  local out
  out="$("$detector" --quiet 2>/dev/null || true)"

  if [[ "$FAMILY" == "auto" ]]; then
    FAMILY="$(printf '%s\n' "$out" | grep -E '^FAMILY=' | tail -1 | cut -d= -f2 || true)"
    [[ -n "$FAMILY" ]] || FAMILY="unknown"
    log_ok "Família detectada: '${FAMILY}'."
  else
    log_info "Família forçada manualmente: '${FAMILY}'."
  fi

  if [[ "$ROLE" != "auto" ]]; then
    log_info "Papel forçado manualmente: '${ROLE}'."
    return 0
  fi

  local detected
  detected="$(printf '%s\n' "$out" | grep -E '^ROLE=' | tail -1 | cut -d= -f2 || true)"
  case "$detected" in
    inference|builder)
      ROLE="$detected"
      log_ok "Papel detectado: '${ROLE}'."
      ;;
    *)
      log_error "Não foi possível detectar o papel automaticamente."
      log_error "Rode './detect-hardware.sh' para inspecionar e use --role inference|builder."
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Etapas
# ---------------------------------------------------------------------------
# Constrói (via echo) as flags repassadas aos scripts filhos.
# Emitidas uma por linha para consumo com mapfile.
child_flags() {
  if [[ $DRY_RUN -eq 1 ]]; then printf '%s\n' --dry-run; fi
  if [[ $ASSUME_YES -eq 1 ]]; then printf '%s\n' --yes; fi
  return 0
}

run_system_mods() {
  if [[ $SKIP_MODS -eq 1 ]]; then
    log_warn "Mods do conjunto 'system' puladas (--skip-mods)."
    return 0
  fi
  log_info "=== Etapa 1/5: Mods do conjunto 'system' ==="
  local engine="${MODS_DIR}/apply.sh"
  require_file "$engine"
  local -a flags=()
  mapfile -t flags < <(child_flags)
  run "Aplicando conjunto 'system'" bash "$engine" apply --set system "${flags[@]}"
}

# ---------------------------------------------------------------------------
# Etapa 2/5 — Chat da frota (`ai-talk`, ADR-003)
# ---------------------------------------------------------------------------
# POR QUE ANTES DO PAPEL: se a instalação do papel falhar, a máquina precisa
# poder CONTAR isso pela rede. O chat é o canal de relato da frota; instalá-lo
# depois da inferência inverteria a ordem de utilidade.
#
# POR QUE DEGRADA: o chat não pode impedir a inferência de subir (Regra 13-a).
# Falha aqui vira AVISO; o `set -e` do build continua valendo para o resto.
run_chat_install() {
  local installer="${SCRIPT_DIR}/talk/install.sh"
  if [[ ! -f "$installer" ]]; then
    log_warn "talk/install.sh não encontrado; chat da frota NÃO será instalado."
    return 0
  fi

  # `AI_CHAT_INSTALL` vem do firstboot.sh (ISO com --chat-*). Numa execução
  # manual sem a variável, o padrão é NÃO instalar: quem quer o chat numa
  # máquina já instalada roda o talk/install.sh explícito (com a chave na mão).
  if [[ "${AI_CHAT_INSTALL:-0}" != "1" ]]; then
    log_info "=== Etapa 2/5: Chat da frota: não solicitado (sem AI_CHAT_INSTALL=1) ==="
    return 0
  fi

  log_info "=== Etapa 2/5: Chat da frota (ai-talk) ==="
  local -a args=(--node "${AI_CHAT_NODE:-$(hostname -s 2>/dev/null || echo ai-cpu-os)}")
  args+=(--role "$ROLE")
  [[ -n "${AI_CHAT_PORT:-}" ]]      && args+=(--port "$AI_CHAT_PORT")
  [[ -n "${AI_CHAT_BIND:-}" ]]      && args+=(--bind "$AI_CHAT_BIND")
  [[ -n "${AI_CHAT_KEY_FILE:-}" ]]  && args+=(--key-file "$AI_CHAT_KEY_FILE")
  [[ -n "${AI_CHAT_KEYDIR:-}" ]]    && args+=(--keydir "$AI_CHAT_KEYDIR")
  [[ -n "${AI_CHAT_PEERS_FILE:-}" ]] && args+=(--peers-file "$AI_CHAT_PEERS_FILE")
  [[ $DRY_RUN -eq 1 ]] && args+=(--dry-run)
  [[ $ASSUME_YES -eq 1 ]] && args+=(--yes)

  if bash "$installer" "${args[@]}"; then
    log_ok "chat da frota instalado."
  else
    # AVISO, não erro: a inferência é o objetivo do projeto; o chat é o canal.
    log_warn "o chat da frota NÃO foi instalado (rc=$?). Seguindo com o papel."
    log_warn "  Conserte depois com: sudo bash ${installer} --help"
  fi
}

run_role_install() {
  log_info "=== Etapa 3/5: Instalação do papel '${ROLE}' (família ${FAMILY}) ==="
  local installer="${ROLES_DIR}/${ROLE}/install.sh"
  require_file "$installer"
  local -a flags=()
  mapfile -t flags < <(child_flags)
  # A família é repassada por ambiente; os scripts de papel usam o
  # llama-build.sh, que resolve a ISA sozinho (ou respeita AI_FAMILY).
  export AI_FAMILY="$FAMILY"
  # Modelo e fonte locais (caminho offline). Exportados porque os scripts de
  # papel/llama-build.sh os leem do ambiente — ver roles/inference/install.sh
  # (AI_MODEL_FILE) e llama-build.sh (AI_LLAMA_SOURCE).
  if [[ -n "$AI_MODEL_FILE_SRC" ]]; then
    export AI_MODEL_FILE="$AI_MODEL_FILE_SRC"
    log_info "Modelo local (sem rede): ${AI_MODEL_FILE_SRC}"
  fi
  if [[ -n "$AI_LLAMA_SOURCE_SRC" ]]; then
    export AI_LLAMA_SOURCE="$AI_LLAMA_SOURCE_SRC"
    log_info "Fonte local do llama.cpp (sem rede): ${AI_LLAMA_SOURCE_SRC}"
  fi
  run "Executando ${installer}" bash "$installer" "${flags[@]}"
}

run_verification() {
  log_info "=== Etapa 4/5: Verificação do tuning ==="
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Pularia verificação de sysctl/governor/THP."
    return 0
  fi
  local swapp vfs numa
  swapp="$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
  vfs="$(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo '?')"
  numa="$(sysctl -n kernel.numa_balancing 2>/dev/null || echo '?')"
  log_info "vm.swappiness=${swapp} · vm.vfs_cache_pressure=${vfs} · kernel.numa_balancing=${numa}"

  local gov
  gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
  log_info "governor[cpu0]=${gov}"

  local thp
  thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?')"
  log_info "transparent_hugepage=${thp}"
}

# ---------------------------------------------------------------------------
# Acesso remoto: garanta que o servidor SSH exista
# ---------------------------------------------------------------------------
# POR QUE (medido numa instalação real, sessão #36): a ISO pede o SSH ao
# instalador (`ssh: install-server` / `pkgsel`), mas ISSO FALHA EM SILÊNCIO
# quando não há rede durante a instalação. O resultado é a pior máquina
# possível: ela sobe, pega IP, e não tem NENHUM serviço escutando — sem SSH não
# há como entrar nela para consertar (numa máquina sem teclado/tela, é um
# tijolo). Aqui a promessa é cumprida de fato: se o `sshd` não estiver lá,
# instalamos; se não der, gritamos nos três canais que sobram (log, motd e
# /root/LEIA-SSH.md). Nunca falha o build: degradação com aviso (Regra 13-a).
ensure_ssh() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] Verificaria (e instalaria, se preciso) o servidor SSH."
    return 0
  fi

  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    log_ok "Servidor SSH presente."
  else
    log_warn "Servidor SSH AUSENTE: instalando openssh-server."
    if apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq openssh-server >/dev/null 2>&1; then
      log_ok "openssh-server instalado."
    else
      log_error "Não foi possível instalar o openssh-server (sem rede?)."
    fi
  fi

  if command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]]; then
    systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
    systemctl start ssh >/dev/null 2>&1 || systemctl start sshd >/dev/null 2>&1 || true
    if systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1; then
      log_ok "SSH ativo e habilitado no boot."
      rm -f /root/LEIA-SSH.md 2>/dev/null || true
    else
      log_warn "sshd instalado mas o serviço não subiu; confira: systemctl status ssh"
    fi
  else
    {
      echo 'ATENÇÃO: esta máquina está SEM servidor SSH.'
      echo ''
      echo 'Para liberar o acesso remoto:'
      echo '    apt-get update && apt-get install -y openssh-server'
      echo '    systemctl enable --now ssh'
      echo '    ip -4 addr show'
    } > /root/LEIA-SSH.md 2>/dev/null || true
    printf '\nATENÇÃO: máquina SEM SSH. Veja /root/LEIA-SSH.md\n' >> /etc/motd 2>/dev/null || true
  fi
}

run_tests() {
  if [[ $SKIP_TESTS -eq 1 ]]; then
    log_warn "Smoke-test pulado (--skip-tests)."
    return 0
  fi
  log_info "=== Etapa 5/5: Smoke-test ==="
  local t="${TESTS_DIR}/smoke-test.sh"
  if [[ ! -f "$t" ]]; then
    log_warn "smoke-test.sh não encontrado; pulando."
    return 0
  fi
  local -a flags=()
  mapfile -t flags < <(child_flags)
  run "Rodando smoke-test" bash "$t" "${flags[@]+"${flags[@]}"}" || {
    log_warn "Smoke-test reportou falhas (não fatais nesta fase). Veja a saída acima."
  }
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
banner() {
  cat <<'EOF'
  ___   _____      ______ __   __  ___  ____
 / _ \ |_   _|    / ____/| |  | |/ _ \/ ___|
| |_| |  | |_____| |     | |  | | | | \___ \
|  _  |  | |_____| |___  | |__| | |_| |___) |
|_| |_|  |_|      \____|  \____/ \___/|____/
             ai-cpu-os  ·  "1% importa"
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  banner
  log_info "ai-cpu-os build.sh — início"
  log_info "Argumentos: role=${ROLE} family=${FAMILY} dry_run=${DRY_RUN} yes=${ASSUME_YES}"

  start_file_log
  check_root
  check_os

  log_warn "AVX-512 só é habilitado por opt-in explícito e se a CPU realmente tiver — ver docs/FAMILIES.md."

  resolve_role

  if ! confirm "Aplicar mods 'system' e instalar papel '${ROLE}' (família '${FAMILY}') agora?"; then
    log_warn "Cancelado pelo usuário."
    exit 0
  fi

  run_system_mods
  run_chat_install
  run_role_install
  run_verification
  ensure_ssh
  run_tests

  log_ok "Concluído (papel '${ROLE}', família '${FAMILY}')."

  # Avisos de follow-up (reboot pendente, modelo, etc.)
  if [[ $DRY_RUN -eq 0 ]]; then
    log_info "Ações de follow-up possíveis:"
    log_info "  - Se alterou C-states (cmdline), reinicie: sudo reboot"
    log_info "  - Se for o papel 'inference', baixe um modelo e suba o serviço:"
    log_info "      sudo systemctl enable --now ai-server"
    log_info "  - Meça performance: llama-bench (ver README)."
    log_info "  - Mods extras e reversíveis: bash mods/apply.sh list"
    log_info "  - Atualize docs/STATE.md com os resultados (regra do AGENTS.md)."
  fi
}

main "$@"
