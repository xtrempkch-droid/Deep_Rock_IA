#!/usr/bin/env bash
#
# llama-build.sh — compila o llama.cpp para a FAMÍLIA de CPU detectada
# -----------------------------------------------------------------------------
# Este script é COMPARTILHADO por todos os papéis (inferência e builder). Ele
# não conhece mais "xeon" nem "ryzen": pergunta à família qual o `-march` e a
# ISA corretos (ver families/).
#
# Uso:
#   bash llama-build.sh [--family auto|<id>] [--allow-avx512] [--no-avx512]
#                       [--native] [--dir /opt/llama.cpp] [--jobs N]
#                       [--ref REF | --source CAMINHO]
#                       [--dry-run] [--yes]
#
#   --family auto      Detecta a família pelo nome do CPU (padrão).
#   --family <id>      Força uma família (ex.: intel-broadwell, amd-zen2).
#   --allow-avx512     Liga AVX-512 nas famílias com política 'optin'.
#   --no-avx512        Desliga AVX-512 mesmo nas famílias com política 'auto'
#                      (o padrão das CPUs que o têm). Útil para medir AVX2 vs
#                      AVX-512 — o -march cai no fallback sem AVX-512.
#   --assume-family-isa  CROSS-BUILD: confia na ISA declarada pela família em
#                      vez de olhar o /proc/cpuinfo DESTA máquina. É o modo
#                      correto para compilar para OUTRA máquina (CI/release).
#   --native           Usa GGML_NATIVE=ON (compila para ESTA máquina).
#                      ⚠️ O binário passa a NÃO ser portátil entre máquinas.
#   --dir <caminho>    Onde clonar/compilar o llama.cpp (padrão: /opt/llama.cpp).
#   --jobs N           Paralelismo do build (padrão: número de núcleos).
#   --ref REF          Ref do llama.cpp no GitHub (padrão: master). Exige REDE.
#   --source CAMINHO   Fonte LOCAL: um DIRETÓRIO ou um .tar.gz/.tar.xz/.tar.
#                      Não usa rede nem git — é o modo OFFLINE, usado no
#                      primeiro boot de uma ISO air-gapped (ver docs/ISO.md § 8).
#
#   ---- BACKEND DE GPU (OPCIONAL, sempre EXPLÍCITO) -----------------------
#   --gpu CHECK        Compila um backend de GPU. CHECK é um de:
#                        cuda | rocm | vulkan | sycl | metal
#                      Nada é escolhido automaticamente: GPU nunca entra por
#                      acidente. Leia docs/GPU.md ANTES — com GPU, o tuning de
#                      CPU deste projeto passa a ser secundário, e a memória
#                      que limita vira a VRAM (não a RAM).
#   --gpu-check        Somente LEITURA: relata as GPUs presentes e quais
#                      backends parecem compiláveis aqui. Não compila nada.
#   --cmake-extra "…"  Flags extras repassadas ao CMake (ex.:
#                      "-DAMDGPU_TARGETS=gfx803" para a RX 580 no ROCm).
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
REF_SET=0
# --source: fonte LOCAL (diretório ou tarball). Vazio = clonar do GitHub.
# Quando preenchido, NENHUM acesso à rede é feito — é o caminho OFFLINE.
# AI_LLAMA_SOURCE (exportada pelo firstboot.sh da ISO) é o padrão: é assim que o
# 1º boot de uma ISO air-gapped compila sem tocar a rede.
SRC_LOCAL="${AI_LLAMA_SOURCE:-}"
SOURCE_DESC="ref ${LLAMA_REF} (git clone do GitHub)"
# AI_FAMILY (exportada pelo build.sh) permite forçar a família de fora.
FORCE_FAMILY="${AI_FAMILY:-auto}"
USE_NATIVE=0
GPU_BACKEND=""
GPU_CHECK=0
CMAKE_EXTRA=""

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
  local -a need=(cmake make cc pkg-config)
  local extra_pkg=""
  # git só é necessário quando o fonte vem do GitHub. Com --source (offline)
  # não há clone nenhum — exigir git aqui impediria a ISO air-gapped.
  if [[ -z "$SRC_LOCAL" ]]; then
    need=(git "${need[@]}")
    extra_pkg="git "
  elif [[ ! -d "$SRC_LOCAL" ]]; then
    need=(tar "${need[@]}")   # tarball precisa de tar
  fi
  # pkg-config é OBRIGATÓRIO: o backend BLAS do ggml usa find_package(PkgConfig).
  for c in "${need[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_warn "Dependências ausentes: ${missing[*]}"
    if confirm "Instalar build-essential cmake ${extra_pkg}pkg-config libopenblas-dev?"; then
      run "apt update" apt-get update
      # shellcheck disable=SC2086
      run "Instalando dependências de build" apt-get install -y --no-install-recommends \
        build-essential cmake ${extra_pkg}pkg-config libopenblas-dev
    else
      log_error "Dependências ausentes e instalação recusada. Abortando."
      exit 1
    fi
  else
    log_info "Dependências de build presentes."
  fi
}

# ---------------------------------------------------------------------------
# GPU (opcional) — sempre explícito, nunca automático
# ---------------------------------------------------------------------------
# Por que desta forma: o ai-cpu-os é um projeto de inferência em CPU, e todo o
# seu tuning (banda de memória, C-states, governor, huge pages) pressupõe isso.
# Deixar a GPU disponível é razoável; ligá-la em silêncio seria mentir sobre o
# que o sistema é. Por isso: backend obrigatório, avisos antes de compilar e
# registro no AI-CPU-OS-BUILD.txt.
readonly GPU_BACKENDS="cuda rocm vulkan sycl metal"

gpu_cmake_flags() {
  case "$1" in
    cuda)   printf '%s' "-DGGML_CUDA=ON" ;;
    rocm)   printf '%s' "-DGGML_HIP=ON" ;;
    vulkan) printf '%s' "-DGGML_VULKAN=ON" ;;
    sycl)   printf '%s' "-DGGML_SYCL=ON" ;;
    metal)  printf '%s' "-DGGML_METAL=ON" ;;
    *)      return 1 ;;
  esac
}

# Relata o que existe nesta máquina. Somente leitura.
gpu_report() {
  section_gpu() { printf '\n== %s ==\n' "$1"; }
  section_gpu "GPUs presentes"
  local found=0
  if command -v lspci >/dev/null 2>&1; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      printf '  %s\n' "$line"
      found=1
    done < <(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)
  else
    log_warn "lspci ausente (instale pciutils) — não consigo listar as GPUs."
  fi
  [[ $found -eq 1 ]] || log_info "  nenhuma GPU de vídeo/computação detectada"

  section_gpu "Backends: o que parece disponível"
  if command -v nvcc >/dev/null 2>&1; then
    log_info "  cuda    → SIM (nvcc encontrado)"
  elif [[ -d /usr/local/cuda ]]; then
    log_info "  cuda    → talvez (/usr/local/cuda existe, mas sem nvcc no PATH)"
  else
    log_info "  cuda    → não (sem nvcc) — exclusivo NVIDIA"
  fi
  if command -v hipcc >/dev/null 2>&1 || [[ -d /opt/rocm ]]; then
    log_info "  rocm    → SIM (hipcc/ROCm encontrado) — AMD"
  else
    log_info "  rocm    → não (sem ROCm) — requer instalação separada da AMD"
  fi
  if command -v vulkaninfo >/dev/null 2>&1; then
    log_info "  vulkan  → SIM (vulkaninfo encontrado) — mais portátil (NVIDIA/AMD/Intel)"
  else
    log_info "  vulkan  → incerto (sem vulkaninfo) — costuma precisar de libvulkan-dev + loader"
  fi
  log_info "  sycl    → Intel (oneAPI); metal → macOS (Apple Silicon)"

  section_gpu "Antes de seguir, saiba"
  log_warn "Com backend de GPU, o tuning de CPU do ai-cpu-os é SECUNDÁRIO: o que"
  log_warn "passa a limitar é a VRAM, não a banda de RAM. C-states/governor/huge"
  log_warn "pages ainda ajudam (tokenização, I/O, prompts), mas o ganho grande vem"
  log_warn "de fora. Os números de docs/STATE.md NÃO valem para este build."
  log_warn "Detalhes, o que muda e as armadilhas: docs/GPU.md"
}

gpu_announce() {
  local backend="$1" _ok=0 _b
  for _b in $GPU_BACKENDS; do
    [[ "$backend" == "$_b" ]] && _ok=1
  done
  if [[ $_ok -eq 0 ]]; then
    log_error "backend de GPU inválido: '${backend}' (use: ${GPU_BACKENDS})"
    exit 2
  fi

  printf '\n== %s ==\n' "Backend de GPU: ${backend}"
  log_warn "Ativado EXPLICITAMENTE por --gpu ${backend}: $(gpu_cmake_flags "$backend")"
  log_warn "O ai-cpu-os nasceu como projeto de inferência 100% em CPU — com GPU,"
  log_warn "parte do tuning daqui passa a ser irrelevante. Leia docs/GPU.md."
  log_info "Ficará registrado no AI-CPU-OS-BUILD.txt (para ninguém comparar maçãs com laranjas)."
}

# ---------------------------------------------------------------------------
# Fonte
# ---------------------------------------------------------------------------
# Duas origens possíveis, e a diferença não é cosmética:
#   • GitHub (--ref)  → exige REDE. É o uso interativo normal.
#   • local (--source)→ ZERO rede. É o que permite compilar no primeiro boot
#                       de uma ISO air-gapped, com o fonte pinado na mídia.
prepare_source() {
  if [[ -n "$SRC_LOCAL" ]]; then
    prepare_source_local
    return 0
  fi

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

# Materializa um fonte LOCAL em SRC_DIR. Sem rede, sem git, sem surpresa:
# o que está na mídia é exatamente o que será compilado (auditável).
prepare_source_local() {
  [[ -e "$SRC_LOCAL" ]] \
    || { log_error "--source '${SRC_LOCAL}': caminho não existe."; exit 1; }

  if [[ -d "$SRC_LOCAL" ]]; then
    [[ -f "${SRC_LOCAL}/CMakeLists.txt" ]] \
      || { log_error "--source ${SRC_LOCAL}: não parece o llama.cpp (sem CMakeLists.txt)."; exit 1; }
    SOURCE_DESC="diretório local ${SRC_LOCAL}"
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] fonte LOCAL (diretório): ${SRC_LOCAL} → ${SRC_DIR} (sem rede, sem git)"
      return 0
    fi
    run "Preparando ${SRC_DIR}" mkdir -p "$SRC_DIR"
    # Sem --delete: preservamos um build/ existente para recompilar mais rápido.
    if command -v rsync >/dev/null 2>&1; then
      run "Copiando fonte local" rsync -a --exclude build/ "${SRC_LOCAL}/" "${SRC_DIR}/"
    else
      run "Copiando fonte local" cp -a "${SRC_LOCAL}/." "$SRC_DIR/"
    fi
    return 0
  fi

  local base; base="$(basename "$SRC_LOCAL")"
  case "$base" in
    *.tar.gz|*.tgz|*.tar.xz|*.tar.bz2|*.tar) ;;
    *) log_error "--source ${SRC_LOCAL}: formato não reconhecido (use um diretório ou .tar.gz/.tar.xz/.tar)."
       exit 1 ;;
  esac
  SOURCE_DESC="tarball local ${base}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] fonte LOCAL (tarball): ${SRC_LOCAL} → ${SRC_DIR} (sem rede, sem git)"
    return 0
  fi

  run "Preparando ${SRC_DIR}" mkdir -p "$SRC_DIR"
  local tmp; tmp="$(mktemp -d)"
  if ! tar -xf "$SRC_LOCAL" -C "$tmp"; then
    rm -rf "$tmp"
    log_error "Falha ao extrair ${SRC_LOCAL}."
    exit 1
  fi

  # Um tarball do GitHub tem um diretório de topo (llama.cpp-<ref>/). Se houver
  # exatamente um diretório e nenhum CMakeLists.txt na raiz, entramos nele.
  # (Glob em vez de `find | head`: com `pipefail`, um SIGPIPE do head reprovaria
  #  a extração sem motivo — armadilha já registrada no JOURNAL.md § 6.)
  local root="$tmp"
  if [[ ! -f "${tmp}/CMakeLists.txt" ]]; then
    local -a subdirs=("$tmp"/*/)
    if [[ ${#subdirs[@]} -eq 1 && -d "${subdirs[0]}" ]]; then
      root="${subdirs[0]}"
    fi
  fi
  if [[ ! -f "${root}/CMakeLists.txt" ]]; then
    rm -rf "$tmp"
    log_error "--source ${SRC_LOCAL}: o tarball não contém CMakeLists.txt (não é o llama.cpp?)."
    exit 1
  fi

  run "Copiando fonte para ${SRC_DIR}" cp -a "${root}/." "$SRC_DIR/"
  rm -rf "$tmp"
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

  # ---------------------------------------------------------------------------
  # GPU (opcional) — entra ANTES de imprimir as flags, para que apareçam na
  # lista. A captura é só do valor de gpu_cmake_flags; os avisos são emitidos
  # por gpu_announce (que loga direto, sem passar por $( )  — senão o texto do
  # log entraria dentro do argumento do cmake).
  # ---------------------------------------------------------------------------
  local gpu_line="nenhum (build 100% CPU)"
  if [[ -n "$GPU_BACKEND" ]]; then
    gpu_announce "$GPU_BACKEND"
    cmake_flags+=("$(gpu_cmake_flags "$GPU_BACKEND")")
    gpu_line="${GPU_BACKEND} ($(gpu_cmake_flags "$GPU_BACKEND"))"
  fi

  # Escape hatch para casos de GPU/ambiente que exigem flags próprias
  # (ex.: -DAMDGPU_TARGETS=gfx803 para a RX 580 Polaris no ROCm).
  local extra
  for extra in ${CMAKE_EXTRA:-}; do
    cmake_flags+=("$extra")
  done
  [[ -n "$CMAKE_EXTRA" ]] && log_info "Flags extras (--cmake-extra): ${CMAKE_EXTRA}"

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
GPU:       ${gpu_line}
AVX-512:   ${AVX512_ENABLED}
Native:    $( [[ $USE_NATIVE -eq 1 ]] && echo "sim (só roda nesta máquina)" || echo "não (portátil para a família)" )
llama.cpp: ${SOURCE_DESC}
Rede:      $( [[ -n "$SRC_LOCAL" ]] && echo "não usada (fonte local)" || echo "sim (clone do GitHub)" )
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
      --ref)           [[ $# -ge 2 ]] || { log_error "--ref exige valor"; exit 2; }; LLAMA_REF="$2"; REF_SET=1; shift 2 ;;
      --source)        [[ $# -ge 2 ]] || { log_error "--source exige valor"; exit 2; }; SRC_LOCAL="$2"; shift 2 ;;
      --family)        [[ $# -ge 2 ]] || { log_error "--family exige valor"; exit 2; }; FORCE_FAMILY="$2"; shift 2 ;;
      --allow-avx512)  export AI_ALLOW_AVX512=1; shift ;;
      --no-avx512)     export AI_NO_AVX512=1; shift ;;
      --assume-family-isa) export AI_ASSUME_FAMILY_ISA=1; shift ;;
      --native)        USE_NATIVE=1; shift ;;
      --gpu)           [[ $# -ge 2 ]] || { log_error "--gpu exige o backend"; exit 2; }; GPU_BACKEND="$2"; shift 2 ;;
      --gpu-check)     GPU_CHECK=1; shift ;;
      --cmake-extra)   [[ $# -ge 2 ]] || { log_error "--cmake-extra exige valor"; exit 2; }; CMAKE_EXTRA="$2"; shift 2 ;;
      -h|--help)
        sed -n '3,31p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; exit 2 ;;
    esac
  done

  log_info "=== llama-build.sh ==="

  # --source e --ref são mutuamente exclusivos: o fonte local já É uma versão
  # específica, então pedir as duas coisas é contradição.
  if [[ -n "$SRC_LOCAL" && $REF_SET -eq 1 ]]; then
    log_error "--ref e --source são mutuamente exclusivos (o fonte local já define a versão)."
    exit 2
  fi

  # --gpu-check é somente leitura: relata e sai, sem compilar nada.
  if [[ $GPU_CHECK -eq 1 ]]; then
    gpu_report
    exit 0
  fi

  if [[ -n "$GPU_BACKEND" ]]; then
    gpu_announce "$GPU_BACKEND"
    if [[ "$GPU_BACKEND" == "metal" ]]; then
      log_warn "metal só existe em macOS: neste Linux o build provavelmente falhará."
    fi
  fi

  resolve_family
  check_deps
  prepare_source
  build
  if [[ -n "$GPU_BACKEND" ]]; then
    log_ok "llama-build.sh concluído (família ${FAMILY_ID}, GPU ${GPU_BACKEND})."
    log_warn "Registre nos benchmarks que este build usa GPU — os números de CPU não valem."
  else
    log_ok "llama-build.sh concluído (família ${FAMILY_ID})."
  fi
  log_info "Teste: ${SRC_DIR}/build/bin/llama-bench -m <modelo>.gguf -t ${JOBS}"
}

main "$@"
