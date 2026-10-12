#!/usr/bin/env bash
#
# llama-build.sh — compila o llama.cpp para a FAMÍLIA de CPU detectada
# -----------------------------------------------------------------------------
# Este script é COMPARTILHADO por todos os papéis (inferência e builder). Ele
# não conhece mais "xeon" nem "ryzen": pergunta à família qual o `-march` e a
# ISA corretos (ver families/).
#
# Uso:
#   bash llama-build.sh [--family auto|<id>] [--allow-avx512] [--native]
#                       [--dir /opt/llama.cpp] [--jobs N] [--ref REF]
#                       [--dry-run] [--yes]
#
#   --family auto      Detecta a família pelo nome do CPU (padrão).
#   --family <id>      Força uma família (ex.: intel-broadwell, amd-zen2).
#   --allow-avx512     Liga AVX-512 nas famílias com política 'optin'.
#   --assume-family-isa  CROSS-BUILD: confia na ISA declarada pela família em
#                      vez de olhar o /proc/cpuinfo DESTA máquina. É o modo
#                      correto para compilar para OUTRA máquina (CI/release).
#   --native           Usa GGML_NATIVE=ON (compila para ESTA máquina).
#                      ⚠️ O binário passa a NÃO ser portátil entre máquinas.
#
# ⚠️ DECISÃO IMPORTANTE — por que NÃO usamos GGML_NATIVE=ON por padrão:
#   Se o build acontecer numa máquina diferente do alvo (ex.: o runner do CI,
#   que pode ter AVX-512), o "native" geraria um binário que sofre SIGILL no
#   alvo (Xeon v3/v4 e Ryzen 3500X só têm AVX2). Por isso o padrão é
#   GGML_NATIVE=OFF + flags EXPLÍCITAS da família — o artefato fica portátil
#   para toda a família. Use --native só quando compilar NA máquina alvo.
#
# Idempotente: reaproveita o clone existente e recompila no mesmo diretório.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOLVE_SH="${SCRIPT_DIR}/families/resolve.sh"

DRY_RUN=0
ASSUME_YES=0
SRC_DIR="/opt/llama.cpp"
JOBS="$(nproc --all 2>/dev/null || echo 4)"
LLAMA_REF="master"
# AI_FAMILY (exportada pelo build.sh) permite forçar a família de fora.
FORCE_FAMILY="${AI_FAMILY:-auto}"
USE_NATIVE=0

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

# ---------------------------------------------------------------------------
# Família (delega para families/resolve.sh)
# ---------------------------------------------------------------------------
resolve_family() {
  [[ -f "$RESOLVE_SH" ]] || { log_error "não encontrei ${RESOLVE_SH}"; exit 1; }
  # shellcheck source=/dev/null
  . "$RESOLVE_SH"
  read_cpu_env
  if [[ "$FORCE_FAMILY" == "auto" ]]; then
    pick_family "$CPU_MODEL"
  else
    FAMILY_ID="$FORCE_FAMILY"
    FAMILY_MATCH_REASON="forçada por --family"
  fi
  load_family "$FAMILY_ID"
  compute_isa

  log_info "CPU:     ${CPU_MODEL:-desconhecido}"
  log_info "Família: ${FAMILY_ID} — ${FAMILY_NAME}"
  log_info "Seleção: ${FAMILY_MATCH_REASON:-—}"
  log_info "March:   ${FAMILY_MARCH_EFFECTIVE:-<nenhum: usa a ISA detectada>}"
  [[ -n "${FAMILY_MARCH_NOTE:-}" ]] && log_warn "$FAMILY_MARCH_NOTE"
  log_info "ISA:     ${FAMILY_ISA_FINAL}"
  if [[ "${AI_ASSUME_FAMILY_ISA:-0}" == "1" ]]; then
    log_warn "CROSS-BUILD: a ISA vem do family.conf, não desta máquina."
  elif [[ -n "${FAMILY_ISA_MISSING:-}" ]]; then
    log_warn "Esta CPU não tem: ${FAMILY_ISA_MISSING}"
    log_warn "O binário gerado continua válido, mas não usará essas instruções."
    log_warn "Se você forçar --family ${FAMILY_ID} em OUTRA máquina, confira se ela tem as flags."
  fi
  log_info "AVX-512: ${AVX512_ENABLED} (${AVX512_REASON})"
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  local c
  # pkg-config é OBRIGATÓRIO: o backend BLAS do ggml usa find_package(PkgConfig).
  for c in git cmake make cc pkg-config; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Dependências ausentes: ${missing[*]}"
    if confirm "Instalar build-essential cmake git pkg-config libopenblas-dev?"; then
      run "apt update" apt-get update
      run "Instalando dependências de build" apt-get install -y --no-install-recommends \
        build-essential cmake git pkg-config libopenblas-dev
    else
      log_error "Dependências ausentes e instalação recusada. Abortando."
      exit 1
    fi
  else
    log_info "Dependências de build presentes."
  fi
}

# ---------------------------------------------------------------------------
# Fonte
# ---------------------------------------------------------------------------
prepare_source() {
  if [[ -d "${SRC_DIR}/.git" ]]; then
    log_info "Repositório já clonado em ${SRC_DIR}."
    if confirm "Atualizar para '${LLAMA_REF}' (git fetch + checkout)?"; then
      run "git fetch" git -C "$SRC_DIR" fetch --all --prune
      run "git checkout" git -C "$SRC_DIR" checkout "$LLAMA_REF"
    fi
  else
    log_info "Clonando llama.cpp em ${SRC_DIR} (ref=${LLAMA_REF})."
    run "Criando diretório pai" mkdir -p "$(dirname "$SRC_DIR")"
    run "git clone" git clone --depth 1 --branch "$LLAMA_REF" \
      https://github.com/ggml-org/llama.cpp.git "$SRC_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build() {
  local -a cmake_flags=()

  # Native = compila para ESTA máquina. Padrão: OFF (portátil para a família).
  if [[ $USE_NATIVE -eq 1 ]]; then
    cmake_flags+=("-DGGML_NATIVE=ON")
    log_warn "--native: o binário valerá para ESTA máquina apenas (não é portátil entre modelos da família)."
  else
    cmake_flags+=("-DGGML_NATIVE=OFF")
  fi

  # ISA explícita vinda da família (só entra o que a CPU de fato tem).
  local f
  for f in ${FAMILY_GGML_FLAGS:-}; do
    cmake_flags+=("$f")
  done

  cmake_flags+=("-DGGML_BLAS=ON" "-DGGML_BLAS_VENDOR=OpenBLAS")
  cmake_flags+=("-DCMAKE_BUILD_TYPE=Release")
  cmake_flags+=("-DLLAMA_CURL=OFF")

  # -march/-mtune da família (respeitando o fallback do compilador).
  if [[ -n "${FAMILY_MARCH_EFFECTIVE:-}" ]]; then
    cmake_flags+=("-DCMAKE_C_FLAGS=${FAMILY_MARCH_EFFECTIVE} -O3")
    cmake_flags+=("-DCMAKE_CXX_FLAGS=${FAMILY_MARCH_EFFECTIVE} -O3")
  fi

  log_info "Flags de CMake (família ${FAMILY_ID}):"
  printf '    %s\n' "${cmake_flags[@]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] cd ${SRC_DIR} && cmake -B build ${cmake_flags[*]}"
    log_info "[dry-run] cmake --build build --config Release -j ${JOBS}"
    return 0
  fi

  ( cd "$SRC_DIR" && cmake -B build "${cmake_flags[@]}" )
  ( cd "$SRC_DIR" && cmake --build build --config Release -j "$JOBS" )

  local bin="${SRC_DIR}/build/bin"
  if [[ -x "${bin}/llama-cli" || -x "${bin}/main" ]]; then
    log_ok "Build concluído. Binários em ${bin}."
    ls -1 "$bin" | sed 's/^/    | /' || true
    # Grava o que foi compilado (útil para auditar portabilidade).
    cat > "${bin}/AI-CPU-OS-BUILD.txt" <<EOF
ai-cpu-os — binário compilado para a família de CPU
Família:   ${FAMILY_ID} (${FAMILY_NAME})
March:     ${FAMILY_MARCH_EFFECTIVE:-<nenhum>}
ISA:       ${FAMILY_ISA_FINAL}
AVX-512:   ${AVX512_ENABLED}
Native:    $( [[ $USE_NATIVE -eq 1 ]] && echo "sim (só roda nesta máquina)" || echo "não (portátil para a família)" )
llama.cpp: ${LLAMA_REF}
Data:      $(_ts)
Nota:      gerado por llama-build.sh — ver docs/FAMILIES.md
EOF
    log_info "Registro do build: ${bin}/AI-CPU-OS-BUILD.txt"
  else
    log_error "Build terminou mas não encontrei os binários em ${bin}."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)       DRY_RUN=1; shift ;;
      --yes)           ASSUME_YES=1; shift ;;
      --dir)           [[ $# -ge 2 ]] || { log_error "--dir exige valor"; exit 2; }; SRC_DIR="$2"; shift 2 ;;
      --jobs)          [[ $# -ge 2 ]] || { log_error "--jobs exige valor"; exit 2; }; JOBS="$2"; shift 2 ;;
      --ref)           [[ $# -ge 2 ]] || { log_error "--ref exige valor"; exit 2; }; LLAMA_REF="$2"; shift 2 ;;
      --family)        [[ $# -ge 2 ]] || { log_error "--family exige valor"; exit 2; }; FORCE_FAMILY="$2"; shift 2 ;;
      --allow-avx512)  export AI_ALLOW_AVX512=1; shift ;;
      --assume-family-isa) export AI_ASSUME_FAMILY_ISA=1; shift ;;
      --native)        USE_NATIVE=1; shift ;;
      -h|--help)
        sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  log_info "=== llama-build.sh ==="
  resolve_family
  check_deps
  prepare_source
  build
  log_ok "llama-build.sh concluído (família ${FAMILY_ID})."
  log_info "Teste: ${SRC_DIR}/build/bin/llama-bench -m <modelo>.gguf -t ${JOBS}"
}

main "$@"
