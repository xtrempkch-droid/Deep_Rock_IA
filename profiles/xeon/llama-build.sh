#!/usr/bin/env bash
#
# profiles/xeon/llama-build.sh — Compila o llama.cpp para Haswell-EP (AVX2)
# -----------------------------------------------------------------------------
# Alvo: Intel Xeon E5-2678 v3 (Haswell-EP, AVX2/FMA/F16C — SEM AVX-512).
#
# Valida as flags de ISA em /proc/cpuinfo ANTES de compilar e faz fallback
# seguro: se uma flag não existir, ela é desabilitada em vez de causar SIGILL.
#
# Uso:
#   bash profiles/xeon/llama-build.sh [--dry-run] [--yes] [--dir /opt/llama.cpp]
#                                     [--jobs N] [--ref <tag/branch>]
#                                     [--march "-march=znver2 -mtune=znver2"]
#
# O parâmetro --march permite reutilizar este mesmo script no perfil ryzen
# (ver profiles/ryzen/llama-build.sh, um wrapper que passa -march=znver2).
#
# Idempotente: recompila apenas quando o diretório-fonte muda ou não há build.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
SRC_DIR="/opt/llama.cpp"
JOBS="$(nproc --all 2>/dev/null || echo 4)"
LLAMA_REF="master"
# Flags extra de arquitetura (ex.: "-march=znver2 -mtune=znver2").
# Vazio por padrão: o perfil xeon confia em GGML_NATIVE=ON + detecção de ISA.
MARCH_FLAGS=""

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
# Validação de ISA — consulta /proc/cpuinfo em tempo de execução.
# ---------------------------------------------------------------------------
HAS_AVX2=0; HAS_FMA=0; HAS_F16C=0; HAS_AVX512=0

detect_isa() {
  local flags
  flags="$(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' || true)"
  has() { grep -qx "$1" <<<"$flags"; }
  has avx2 && HAS_AVX2=1
  has fma  && HAS_FMA=1
  has f16c && HAS_F16C=1
  has avx512f && HAS_AVX512=1

  log_info "ISA detectada: AVX2=${HAS_AVX2} FMA=${HAS_FMA} F16C=${HAS_F16C} AVX-512=${HAS_AVX512}"
  if [[ $HAS_AVX512 -eq 1 ]]; then
    log_warn "AVX-512 detectado nesta CPU — o alvo (E5-2678 v3) NÃO tem AVX-512."
    log_warn "O script não habilita AVX-512 por padrão. Ajuste manualmente se souber o que faz."
  fi
  if [[ $HAS_AVX2 -eq 0 ]]; then
    log_warn "AVX2 não disponível: build rodará em modo genérico (mais lento)."
  fi
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
check_deps() {
  local missing=()
  local c
  for c in git cmake make cc; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Dependências ausentes: ${missing[*]}"
    if confirm "Instalar libopenblas-dev build-essential cmake git clang?"; then
      run "apt update" apt-get update
      run "Instalando dependências de build" apt-get install -y --no-install-recommends \
        build-essential cmake git libopenblas-dev
    else
      log_error "Dependências ausentes e instalação recusada. Abortando."
      exit 1
    fi
  else
    log_info "Dependências de build presentes."
  fi
}

# ---------------------------------------------------------------------------
# Clone/atualização do llama.cpp
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
# Compilação
# ---------------------------------------------------------------------------
build() {
  local cmake_flags=()
  cmake_flags+=("-DGGML_NATIVE=ON")       # usa a ISA real da CPU (seguro)
  if [[ $HAS_AVX2 -eq 1 ]]; then cmake_flags+=("-DGGML_AVX2=ON"); fi
  if [[ $HAS_FMA  -eq 1 ]]; then cmake_flags+=("-DGGML_FMA=ON");  fi
  if [[ $HAS_F16C -eq 1 ]]; then cmake_flags+=("-DGGML_F16C=ON"); fi
  cmake_flags+=("-DGGML_BLAS=ON" "-DGGML_BLAS_VENDOR=OpenBLAS")
  # -march/-mtune específicos (ex.: znver2 no perfil ryzen). Vazio = não passa.
  # Passamos C e C++ porque o ggml compila unidades em ambas as linguagens.
  if [[ -n "$MARCH_FLAGS" ]]; then
    cmake_flags+=("-DCMAKE_C_FLAGS=${MARCH_FLAGS} -O3")
    cmake_flags+=("-DCMAKE_CXX_FLAGS=${MARCH_FLAGS} -O3")
  fi
  cmake_flags+=("-DCMAKE_BUILD_TYPE=Release")
  cmake_flags+=("-DLLAMA_CURL=OFF")       # evita depender de libcurl no alvo

  log_info "Flags de CMake: ${cmake_flags[*]}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] cd ${SRC_DIR} && cmake -B build ${cmake_flags[*]}"
    log_info "[dry-run] cmake --build build --config Release -j ${JOBS}"
    return 0
  fi

  ( cd "$SRC_DIR" && cmake -B build "${cmake_flags[@]}" )
  ( cd "$SRC_DIR" && cmake --build build --config Release -j "$JOBS" )

  # Verifica artefatos
  local bin="${SRC_DIR}/build/bin"
  if [[ -x "${bin}/llama-cli" || -x "${bin}/main" ]]; then
    log_ok "Build concluído. Binários em ${bin}."
    ls -1 "$bin" | sed 's/^/    | /' || true
  else
    log_error "Build terminou mas binários esperados não foram encontrados em ${bin}."
    exit 1
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
      --dir)     [[ $# -ge 2 ]] || { log_error "--dir exige valor"; exit 2; }; SRC_DIR="$2"; shift 2 ;;
      --jobs)    [[ $# -ge 2 ]] || { log_error "--jobs exige valor"; exit 2; }; JOBS="$2"; shift 2 ;;
      --ref)     [[ $# -ge 2 ]] || { log_error "--ref exige valor"; exit 2; }; LLAMA_REF="$2"; shift 2 ;;
      --march)   [[ $# -ge 2 ]] || { log_error "--march exige valor"; exit 2; }; MARCH_FLAGS="$2"; shift 2 ;;
      -h|--help) echo "Uso: $0 [--dry-run] [--yes] [--dir DIR] [--jobs N] [--ref REF] [--march FLAGS]"; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  log_info "=== llama-build.sh (perfil xeon / Haswell-EP AVX2) ==="
  log_warn "Antes de continuar: o Xeon E5-2678 v3 NÃO possui AVX-512 (apenas AVX2)."

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_warn "Rodando sem root: clones em ${SRC_DIR} podem exigir sudo."
  fi

  detect_isa
  check_deps
  prepare_source
  build

  if [[ -n "$MARCH_FLAGS" ]]; then
    log_info "Flags de arquitetura aplicadas: ${MARCH_FLAGS}"
  fi

  log_ok "llama-build.sh concluído."
  log_info "Teste com: ${SRC_DIR}/build/bin/llama-bench -m <modelo>.gguf -t ${JOBS}"
}

main "$@"
