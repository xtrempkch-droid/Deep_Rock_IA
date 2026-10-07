#!/usr/bin/env bash
#
# detect-hardware.sh — Detecção automática de hardware do ai-cpu-os
# -----------------------------------------------------------------------------
# Detecta CPU (modelo, núcleos, threads), flags ISA (AVX2/AVX-512/AMX),
# RAM total, canais de memória (single/dual) e tipo de armazenamento
# (NVMe vs SATA). Ao final, imprime a linha 'PROFILE=<xeon|ryzen>' para
# consumo pelo build.sh.
#
# Uso:
#   ./detect-hardware.sh            # relatório completo
#   ./detect-hardware.sh --quiet    # apenas a linha PROFILE=...
#
# Este script é SOMENTE LEITURA — não altera nada no sistema.
# -----------------------------------------------------------------------------

set -euo pipefail

QUIET=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi

log_info()  { [[ $QUIET -eq 1 ]] && return 0; printf '%b[i]%b %s\n' "$C_INFO" "$C_RESET" "$*"; }
log_warn()  { printf '%b[warn]%b %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[err]%b %s\n'  "$C_ERR"  "$C_RESET" "$*" >&2; }
log_ok()    { [[ $QUIET -eq 1 ]] && return 0; printf '%b[ok]%b %s\n' "$C_OK" "$C_RESET" "$*"; }
section()   { [[ $QUIET -eq 1 ]] && return 0; printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() {
  cat <<'EOF'
detect-hardware.sh — relatório de hardware e escolha de perfil

Uso:
  ./detect-hardware.sh [--quiet]

  --quiet    Imprime somente a linha 'PROFILE=<xeon|ryzen>'.
  -h|--help  Mostra esta ajuda.

Variáveis:
  AI_DIMMS_PER_CHANNEL   Override da heurística de canais (ex.: 2).
EOF
}

# ---------------------------------------------------------------------------
# CPU
# ---------------------------------------------------------------------------
CPU_MODEL=""
CPU_VENDOR=""
CPU_SOCKETS=1
CPU_CORES=0
CPU_THREADS=0

detect_cpu() {
  section "CPU"
  if ! command -v lscpu >/dev/null 2>&1; then
    log_warn "lscpu indisponível; usando /proc/cpuinfo."
  fi

  CPU_MODEL="$(grep -m1 -E 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//' || true)"
  CPU_VENDOR="$(grep -m1 -E 'vendor_id' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//' || true)"

  if command -v lscpu >/dev/null 2>&1; then
    CPU_SOCKETS="$(lscpu | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}')"
    CPU_CORES="$(lscpu | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')"
    CPU_THREADS="$(nproc --all 2>/dev/null || grep -c '^processor' /proc/cpuinfo)"
    [[ -z "$CPU_SOCKETS" ]] && CPU_SOCKETS=1
    [[ -z "$CPU_CORES" ]] && CPU_CORES="$CPU_THREADS"
    [[ -z "$CPU_THREADS" ]] && CPU_THREADS=1
  else
    CPU_SOCKETS=1
    CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo || echo 1)"
    CPU_CORES="$CPU_THREADS"
  fi

  log_info "Modelo:      ${CPU_MODEL:-desconhecido}"
  log_info "Fabricante:  ${CPU_VENDOR:-desconhecido}"
  log_info "Sockets:     ${CPU_SOCKETS}"
  log_info "Núcleos:     ${CPU_CORES} (por socket)"
  log_info "Threads:     ${CPU_THREADS} (total)"
}

# ---------------------------------------------------------------------------
# Flags ISA
# ---------------------------------------------------------------------------
HAS_AVX2=0
HAS_AVX512=0
HAS_AMX=0
HAS_FMA=0
HAS_F16C=0

detect_isa() {
  section "Flags ISA"
  local flags
  flags="$(grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' || true)"

  has() { grep -qx "$1" <<<"$flags"; }

  has avx2   && HAS_AVX2=1
  has fma    && HAS_FMA=1
  has f16c   && HAS_F16C=1
  has amx_tile && HAS_AMX=1
  # AVX-512: basta uma das flags para considerar suporte (checamos a base)
  if has avx512f || has avx512d; then HAS_AVX512=1; fi

  yn() { [[ "$1" -eq 1 ]] && echo "SIM" || echo "NÃO"; }
  log_info "AVX2:    $(yn "$HAS_AVX2")"
  log_info "FMA:     $(yn $HAS_FMA)"
  log_info "F16C:    $(yn $HAS_F16C)"
  log_info "AVX-512: $(yn $HAS_AVX512)"
  log_info "AMX:     $(yn $HAS_AMX)"

  if [[ $HAS_AVX512 -eq 1 ]]; then
    log_warn "AVX-512 detectado — hardware não é o alvo típico (Xeon E5-2678 v3 / Ryzen 5 3500X não têm AVX-512)."
  else
    log_ok "Sem AVX-512/AMX (esperado para os hardwares alvo)."
  fi
}

# ---------------------------------------------------------------------------
# RAM e canais
# ---------------------------------------------------------------------------
RAM_TOTAL_MB=0
RAM_CANNELS="desconhecido"

detect_ram() {
  section "Memória"
  local kb
  kb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
  RAM_TOTAL_MB=$(( kb / 1024 ))
  log_info "Total:       ${RAM_TOTAL_MB} MiB (~$(( RAM_TOTAL_MB / 1024 )) GiB)"

  # Detecção de canais.
  # Preferência 1: dmidecode (root). Preferência 2: lshw. Fallback: heurística.
  local dmidecode_out=""
  if command -v dmidecode >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    dmidecode_out="$(dmidecode -t 17 2>/dev/null || true)"
  fi

  local populated=0
  if [[ -n "$dmidecode_out" ]]; then
    populated="$(grep -c '^[[:space:]]*Size:.*[0-9].*MB\|^[[:space:]]*Size:.*GB' <<<"$dmidecode_out" || true)"
    [[ -z "$populated" ]] && populated=0
    log_info "DIMMs populados: ${populated}"
  else
    if command -v lshw >/dev/null 2>&1; then
      populated="$(lshw -short -C memory 2>/dev/null | grep -ciE 'DDR[0-9]|[0-9]+ ?(GiB|GB)' || true)"
      [[ -z "$populated" ]] && populated=0
      log_info "DIMMs (via lshw): ${populated}"
    else
      log_warn "Sem dmidecode (root) nem lshw: canais de memória não podem ser confirmados."
    fi
  fi

  # Heurística de canais: assumindo 2 slots por canal (típico de placas AM4/X99),
  # DIMMs >= 4 => dual channel; 2 DIMMs => provavelmente 1 por canal (dual);
  # 1 DIMM => single channel.
  local per_channel="${AI_DIMMS_PER_CHANNEL:-2}"
  if [[ "$populated" -ge 1 ]]; then
    if [[ "$populated" -le 1 ]]; then
      RAM_CANNELS="single"
    elif [[ "$populated" -ge 2 && "$populated" -lt $(( per_channel * 2 )) ]]; then
      # 2 DIMMs com 1 por canal ainda pode ser dual; com 2 no mesmo canal = single.
      # Sem DMI completo não é possível saber com certeza — reportamos "provável".
      RAM_CANNELS="provável dual (2 DIMMs)"
    else
      RAM_CANNELS="dual"
    fi
  fi

  # Override de canais: se dmidecode expôs 'Bank Locator', tentamos contar canais distintos.
  if [[ -n "$dmidecode_out" ]]; then
    local banks
    banks="$(grep -E '^[[:space:]]*Bank Locator:' <<<"$dmidecode_out" | sed 's/.*Bank Locator: *//' | sort -u | wc -l || echo 0)"
    if [[ "$banks" -ge 2 && "$populated" -ge 2 ]]; then
      RAM_CANNELS="dual (heurística por Bank Locator)"
    fi
  fi

  log_info "Canais:      ${RAM_CANNELS}"

  # Heurística de alerta: single channel é crítico (Ryzen alvo).
  if [[ "$RAM_CANNELS" == "single" ]]; then
    log_warn "MEMÓRIA EM SINGLE CHANNEL — perda de ~50% de banda, crítico para inferência em CPU!"
    log_warn "Nas MSI B550 (AM4), use os slots A2 + B2 para dual channel."
  fi
}

# ---------------------------------------------------------------------------
# Armazenamento
# ---------------------------------------------------------------------------
STORAGE_NVME=0
STORAGE_SATA=0

detect_storage() {
  section "Armazenamento"
  local line name tran model
  # lsblk: TRAN 'nvme' para NVMe, 'sata' para SATA.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="$(awk '{print $1}' <<<"$line")"
    tran="$(awk '{print $2}' <<<"$line")"
    model="$(cut -d' ' -f3- <<<"$line")"
    case "$tran" in
      nvme) STORAGE_NVME=$(( STORAGE_NVME + 1 )); log_info "NVMe: ${name} (${model})" ;;
      sata|ata) STORAGE_SATA=$(( STORAGE_SATA + 1 )); log_info "SATA: ${name} (${model})" ;;
      *) : ;;
    esac
  done < <(lsblk -d -o NAME,TRAN,MODEL -n 2>/dev/null || true)

  if [[ $STORAGE_NVME -eq 0 && $STORAGE_SATA -eq 0 ]]; then
    log_warn "Não foi possível classificar discos (lsblk)."
  else
    log_info "Resumo: ${STORAGE_NVME} NVMe / ${STORAGE_SATA} SATA"
  fi
}

# ---------------------------------------------------------------------------
# Escolha de perfil
# ---------------------------------------------------------------------------
choose_profile() {
  local lower_model
  lower_model="$(tr '[:upper:]' '[:lower:]' <<<"${CPU_MODEL}")"
  local lower_vendor
  lower_vendor="$(tr '[:upper:]' '[:lower:]' <<<"${CPU_VENDOR}")"

  # Regras:
  #   Intel Xeon (ou qualquer Intel Xeon/Silver/Gold/Bronze) → xeon
  #   AMD Ryzen                                             → ryzen
  #   fallback por RAM: <=32GB → xeon (servidor de inferência), >32GB → ryzen (build)
  if [[ "$lower_vendor" == *intel* && "$lower_model" == *xeon* ]]; then
    echo "xeon"
    return 0
  fi
  if [[ "$lower_vendor" == *amd* && "$lower_model" == *ryzen* ]]; then
    echo "ryzen"
    return 0
  fi
  if [[ "$lower_model" == *xeon* ]]; then echo "xeon"; return 0; fi
  if [[ "$lower_model" == *ryzen* ]]; then echo "ryzen"; return 0; fi

  # Fallback por RAM total
  if [[ "$RAM_TOTAL_MB" -le $(( 32 * 1024 )) ]]; then
    echo "xeon"
  else
    echo "ryzen"
  fi
}

# ---------------------------------------------------------------------------
# Recomendações de flags de compilação
# ---------------------------------------------------------------------------
print_recommendations() {
  local profile="$1"
  section "Recomendações de build (llama.cpp)"

  local base="-DGGML_NATIVE=ON"
  [[ $HAS_AVX2 -eq 1 ]] && base+=" -DGGML_AVX2=ON"
  [[ $HAS_FMA  -eq 1 ]] && base+=" -DGGML_FMA=ON"
  [[ $HAS_F16C -eq 1 ]] && base+=" -DGGML_F16C=ON"
  base+=" -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS"

  if [[ "$profile" == "ryzen" ]]; then
    log_info "cmake -B build ${base} -DCMAKE_C_FLAGS=\"-march=znver2 -mtune=znver2 -O3\""
  else
    log_info "cmake -B build ${base}"
  fi

  if [[ $HAS_AVX512 -eq 1 ]]; then
    log_warn "AVX-512 presente, mas NÃO habilitado por padrão (hardware alvo não tem). Ajuste manualmente se desejar."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ $QUIET -eq 0 ]] && {
    printf '%b=================================================%b\n' "$C_BOLD" "$C_RESET"
    printf '%b       ai-cpu-os · detecção de hardware        %b\n' "$C_BOLD" "$C_RESET"
    printf '%b=================================================%b\n' "$C_BOLD" "$C_RESET"
  }

  detect_cpu
  detect_isa
  detect_ram
  detect_storage

  local profile
  profile="$(choose_profile)"

  if [[ $QUIET -eq 0 ]]; then
    section "Resultado"
    log_ok "Perfil escolhido: ${profile}"
    print_recommendations "$profile"

    # Avisos específicos do hardware alvo
    section "Avisos do hardware alvo"
    log_warn "Xeon E5-2678 v3 e Ryzen 5 3500X NÃO possuem AVX-512 (apenas AVX2)."
    if [[ "$profile" == "ryzen" ]]; then
      log_warn "Single channel no Ryzen custa ~50% de banda de memória — verifique os slots."
      log_warn "RX 580: usar APENAS para vídeo, nunca para computação (artefatos sob carga)."
    fi
    if [[ "$profile" == "xeon" ]]; then
      log_warn "16 GB de RAM no Xeon: modelos acima de ~7B Q4 não caberão."
    fi
  fi

  # Linha consumível por scripts.
  printf 'PROFILE=%s\n' "$profile"
}

main "$@"
