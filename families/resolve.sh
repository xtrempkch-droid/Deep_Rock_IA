#!/usr/bin/env bash
#
# families/resolve.sh — descobre a FAMÍLIA do CPU e monta as flags de build
# -----------------------------------------------------------------------------
# Este script é o "cérebro" do suporte por família. Ele:
#   1. Lê o nome do CPU em /proc/cpuinfo;
#   2. Casa contra FAMILY_MATCH_NAME de cada família (families/*/family.conf);
#   3. Carrega a cadeia de herança (_base → ... → família);
#   4. Decide AVX-512 conforme FAMILY_AVX512_POLICY (+ --allow-avx512);
#   5. Exporta FAMILY_ID, FAMILY_MARCH, FAMILY_ISA_FINAL, etc.
#
# Uso como SCRIPT:
#   bash families/resolve.sh                  # relatório legível
#   bash families/resolve.sh --quiet          # imprime só "FAMILY=<id>"
#   bash families/resolve.sh --allow-avx512   # liga AVX-512 (policy=optin)
#
# Uso como BIBLIOTECA (source):
#   source families/resolve.sh
#   pick_family "$CPU_MODEL"; load_family "$FAMILY_ID"; compute_isa
#   echo "$FAMILY_MARCH $FAMILY_ISA_FINAL"
#
# Por que existe: manter suporte a um processador ÚNICO é fechado e desperdiça
# tempo. Uma família compartilha microarquitetura e ISA — otimizar a família
# beneficia todos os modelos dela (ver families/README.md).
# -----------------------------------------------------------------------------

set -euo pipefail

# Diretório deste arquivo (funciona com source e com execução direta).
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _self="${BASH_SOURCE[0]}"
else
  _self="$0"
fi
RESOLVE_FAMILIES_DIR="$(cd "$(dirname "$_self")" && pwd)"
readonly RESOLVE_FAMILIES_DIR

# ---------------------------------------------------------------------------
# Lista de famílias (pastas com family.conf, exceto _base)
# ---------------------------------------------------------------------------
families_available() {
  local d
  for d in "${RESOLVE_FAMILIES_DIR}"/*/; do
    [[ -f "${d}family.conf" ]] || continue
    basename "$d"
  done | grep -v '^_base$' | sort
}

# ---------------------------------------------------------------------------
# Carrega uma família: _base → cadeia de herança → a própria família.
# Cada nível sobrescreve o anterior (por isso a ordem importa).
# ---------------------------------------------------------------------------
load_family() {
  local id="$1"
  local -a chain=()
  local cur="$id"

  # Monta a cadeia seguindo FAMILY_INHERITS (com proteção contra ciclo).
  local guard=0
  while [[ -n "$cur" ]]; do
    guard=$(( guard + 1 ))
    if (( guard > 16 )); then
      echo "resolve.sh: herança circular detectada (${id})" >&2
      return 1
    fi
    chain=("$cur" "${chain[@]+"${chain[@]}"}")
    local f="${RESOLVE_FAMILIES_DIR}/${cur}/family.conf"
    if [[ ! -f "$f" ]]; then
      echo "resolve.sh: família não encontrada: ${cur}" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    cur="$(
      unset FAMILY_INHERITS
      # shellcheck source=/dev/null
      . "$f"
      printf '%s' "${FAMILY_INHERITS:-}"
    )"
  done

  # Carrega _base e depois cada nível da cadeia (raiz → folha).
  # shellcheck source=/dev/null
  . "${RESOLVE_FAMILIES_DIR}/_base/family.conf"
  local lvl
  for lvl in "${chain[@]}"; do
    # shellcheck source=/dev/null
    . "${RESOLVE_FAMILIES_DIR}/${lvl}/family.conf"
  done
}

# ---------------------------------------------------------------------------
# Escolhe a família pelo nome do CPU. Sem match → generic.
# ---------------------------------------------------------------------------
pick_family() {
  local cpu_model="${1:-}"
  local -a order=(
    amd-zen5 amd-zen4 amd-zen3 amd-zen2 amd-zen1
    intel-graniterapids-sp intel-emeraldrapids-sp intel-sapphirerapids-sp
    intel-icelake-sp intel-cascadelake-sp intel-skylake-avx512
    intel-broadwell intel-haswell
  )
  local id f pattern
  for id in "${order[@]}"; do
    f="${RESOLVE_FAMILIES_DIR}/${id}/family.conf"
    [[ -f "$f" ]] || continue
    pattern="$(
      unset FAMILY_MATCH_NAME
      # shellcheck source=/dev/null
      . "$f"
      printf '%s' "${FAMILY_MATCH_NAME:-}"
    )"
    [[ -n "$pattern" ]] || continue
    if [[ "$cpu_model" =~ $pattern ]]; then
      FAMILY_ID="$id"
      FAMILY_MATCH_REASON="nome do CPU casa com '${pattern}'"
      return 0
    fi
  done
  FAMILY_ID="generic"
  FAMILY_MATCH_REASON="nenhuma família casou — usando o fallback 'generic'"
  return 0
}

# ---------------------------------------------------------------------------
# Decide a ISA final (incluindo AVX-512) e resolve o -march conforme o GCC.
# ---------------------------------------------------------------------------
compute_isa() {
  local flags="${CPU_FLAGS:-}"

  # _has_flag responde "a ISA necessária está presente?".
  #
  # Em CROSS-BUILD (AI_ASSUME_FAMILY_ISA=1) não olhamos /proc/cpuinfo: o alvo
  # é OUTRA máquina (ex.: o runner do CI), e o que vale é o que a família
  # declara. Isso evita o bug clássico de compilar com GGML_NATIVE=ON no
  # runner e gerar um binário com AVX-512 que sofre SIGILL no alvo.
  _has_flag() {
    if [[ "${AI_ASSUME_FAMILY_ISA:-0}" == "1" ]]; then
      case " ${FAMILY_ISA_REQUIRED} ${FAMILY_ISA_OPTIONAL:-} " in
        *" $1 "*) return 0 ;;
        *)         return 1 ;;
      esac
    fi
    grep -qw "$1" <<<"$flags"
  }

  # 1. ISA obrigatória: "+flag" se a CPU tem, "-flag" se falta (vira aviso).
  FAMILY_ISA_FINAL=""
  FAMILY_ISA_MISSING=""
  local f
  for f in $FAMILY_ISA_REQUIRED; do
    if _has_flag "$f"; then
      FAMILY_ISA_FINAL="${FAMILY_ISA_FINAL} +${f}"
    else
      FAMILY_ISA_FINAL="${FAMILY_ISA_FINAL} -${f}"
      FAMILY_ISA_MISSING="${FAMILY_ISA_MISSING} ${f}"
    fi
  done
  FAMILY_ISA_FINAL="${FAMILY_ISA_FINAL# }"
  FAMILY_ISA_MISSING="${FAMILY_ISA_MISSING# }"

  # 2. AVX-512 conforme a política da família.
  AVX512_ENABLED="no"
  local has_avx512=0
  if _has_flag avx512f; then has_avx512=1; fi

  # De ONDE vem a verdade sobre a ISA, para o motivo dizer a coisa certa:
  # em cross-build (AI_ASSUME_FAMILY_ISA=1) o alvo é OUTRA máquina e quem
  # declara a flag é o family.conf; no build nativo, é o /proc/cpuinfo desta
  # máquina. Dizer sempre "a CPU reporta" em cross-build seria mentira útil
  # para ninguém — e já confundiu quem lê o relatório (teste avx512).
  local isa_tem isa_nao_tem
  if [[ "${AI_ASSUME_FAMILY_ISA:-0}" == "1" ]]; then
    isa_tem="a família declara avx512f (cross-build: a ISA vem do family.conf, não desta CPU)"
    isa_nao_tem="a família não declara avx512f (cross-build)"
  else
    isa_tem="a CPU reporta avx512f"
    isa_nao_tem="a CPU não reporta avx512f"
  fi

  case "${FAMILY_AVX512_POLICY:-never}" in
    never)
      AVX512_ENABLED="no"
      AVX512_REASON="política 'never': a família ${FAMILY_ID} não tem AVX-512 (habilitar causaria SIGILL)"
      ;;
    optin)
      if [[ "${AI_NO_AVX512:-0}" == "1" ]]; then
        AVX512_ENABLED="no"
        AVX512_REASON="desligado por --no-avx512"
      elif [[ "${AI_ALLOW_AVX512:-0}" == "1" && $has_avx512 -eq 1 ]]; then
        AVX512_ENABLED="yes"
        AVX512_REASON="política 'optin' + --allow-avx512 e ${isa_tem}"
      elif [[ $has_avx512 -eq 0 ]]; then
        AVX512_REASON="política 'optin', mas ${isa_nao_tem}"
      else
        AVX512_REASON="política 'optin': ligue com --allow-avx512 / AI_ALLOW_AVX512=1"
      fi
      ;;
    auto)
      if [[ "${AI_NO_AVX512:-0}" == "1" ]]; then
        AVX512_ENABLED="no"
        AVX512_REASON="política 'auto', mas desligado por --no-avx512"
      elif [[ $has_avx512 -eq 1 ]]; then
        AVX512_ENABLED="yes"
        AVX512_REASON="política 'auto' (padrão da família: CPUs com AVX-512 o usam) e ${isa_tem}"
      else
        AVX512_REASON="política 'auto', mas ${isa_nao_tem}"
      fi
      ;;
    *)
      AVX512_ENABLED="no"
      AVX512_REASON="política desconhecida '${FAMILY_AVX512_POLICY}' — mantendo desligado"
      ;;
  esac

  # 3. O -march pode depender do compilador (ex.: znver4 exige GCC >= 13).
  FAMILY_MARCH_EFFECTIVE="$FAMILY_MARCH"
  FAMILY_MARCH_NOTE=""
  if [[ -n "$FAMILY_MARCH" && -n "${FAMILY_MARCH_MIN_GCC:-}" && "${FAMILY_MARCH_MIN_GCC}" != "0" ]]; then
    local gcc_major="0"
    if command -v gcc >/dev/null 2>&1; then
      gcc_major="$(gcc -dumpversion 2>/dev/null | cut -d. -f1)"
      [[ -z "$gcc_major" ]] && gcc_major="0"
    fi
    if [[ "$gcc_major" -lt "$FAMILY_MARCH_MIN_GCC" ]]; then
      if [[ -n "${FAMILY_MARCH_FALLBACK:-}" ]]; then
        FAMILY_MARCH_EFFECTIVE="$FAMILY_MARCH_FALLBACK"
        FAMILY_MARCH_NOTE="GCC ${gcc_major} < ${FAMILY_MARCH_MIN_GCC}: usando o fallback '${FAMILY_MARCH_FALLBACK}'"
      else
        FAMILY_MARCH_EFFECTIVE=""
        FAMILY_MARCH_NOTE="GCC ${gcc_major} < ${FAMILY_MARCH_MIN_GCC}: sem -march específico"
      fi
    fi
  fi

  # 3-b. AVX-512 DESLIGADO (sem a flag na CPU ou --no-avx512) e o -march da
  # família já habilita AVX-512 por conta própria (skylake-avx512,
  # sapphirerapids, znver4/znver5...): troca para o fallback SEM AVX-512.
  # Sem isto o GCC continuaria emitindo AVX-512 via -march mesmo com a
  # política desligada. Só se o GCC ainda não trocou (senão respeitamos a
  # decisão dele, que já é um fallback).
  if [[ "$AVX512_ENABLED" != "yes" \
        && "${FAMILY_MARCH_HAS_AVX512:-}" == "yes" \
        && -n "${FAMILY_MARCH_FALLBACK:-}" \
        && "${FAMILY_MARCH_EFFECTIVE:-}" == "${FAMILY_MARCH:-}" ]]; then
    FAMILY_MARCH_EFFECTIVE="$FAMILY_MARCH_FALLBACK"
    FAMILY_MARCH_NOTE="AVX-512 desligado: usando o fallback '${FAMILY_MARCH_FALLBACK}' (sem AVX-512)"
  fi

  # 3-c. Coerência `-march` × AVX-512 (o caso do znver4 com GCC antigo).
  # AVX-512 LIGADO, mas o -march efetivo é o fallback, que NÃO tem AVX-512
  # (ex.: znver4→znver3 porque o GCC é 12). Não é erro: as flags do CMake são
  # o que compila AVX-512 e a CPU alvo tem as instruções. Mas sem aviso o
  # relatório diria "AVX-512: yes" com um -mtune de geração anterior, o que
  # confunde quem lê o AI-CPU-OS-BUILD.txt — então AVISAMOS em vez de deixar
  # passar em silêncio.
  if [[ "$AVX512_ENABLED" == "yes" \
        && "${FAMILY_MARCH_HAS_AVX512:-}" == "yes" \
        && "${FAMILY_MARCH_EFFECTIVE:-}" != "${FAMILY_MARCH:-}" ]]; then
    FAMILY_MARCH_NOTE="${FAMILY_MARCH_NOTE:+${FAMILY_MARCH_NOTE} · }Atenção: AVX-512 ligado, mas o -march efetivo ('${FAMILY_MARCH_EFFECTIVE}') não traz AVX-512 — o binário sai com AVX-512 pelas flags do CMake, mas com -mtune de geração anterior. Instale um GCC >= ${FAMILY_MARCH_MIN_GCC:-?} para o -march completo."
  fi

  # 4. Flags do CMake para o llama.cpp (derivadas da família).
  FAMILY_GGML_FLAGS=""
  [[ -n "$FAMILY_ISA_FINAL" ]] || FAMILY_ISA_FINAL="(detecção em runtime)"
  local feat
  for feat in $FAMILY_ISA_REQUIRED; do
    case "$feat" in
      avx2)  _has_flag avx2   && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_AVX2=ON" ;;
      fma)   _has_flag fma    && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_FMA=ON" ;;
      f16c)  _has_flag f16c   && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_F16C=ON" ;;
      avx)   _has_flag avx    && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_AVX=ON" ;;
      *) : ;;
    esac
  done
  if [[ "$AVX512_ENABLED" == "yes" ]]; then
    FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_AVX512=ON"
    _has_flag avx512vnni && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_AVX512_VNNI=ON"
    _has_flag amx_tile   && FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS} -DGGML_AMX=ON"
  fi
  FAMILY_GGML_FLAGS="${FAMILY_GGML_FLAGS# }"
}

# ---------------------------------------------------------------------------
# Helpers públicos
# ---------------------------------------------------------------------------
# Lê o ambiente de CPU (nome + flags). Pode ser chamado pelo chamador.
read_cpu_env() {
  CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)"
  CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2- || true)"
  # shellcheck disable=SC2034  # consumido pelo chamador (detect-hardware.sh etc.)
  CPU_VENDOR="$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || true)"
}

# Monta o -DCMAKE_C_FLAGS/-DCMAKE_CXX_FLAGS a partir do -march efetivo.
family_cmake_march_flags() {
  if [[ -n "${FAMILY_MARCH_EFFECTIVE:-}" ]]; then
    printf '%s' "-DCMAKE_C_FLAGS=${FAMILY_MARCH_EFFECTIVE} -O3 -DCMAKE_CXX_FLAGS=${FAMILY_MARCH_EFFECTIVE} -O3"
  fi
}

# ---------------------------------------------------------------------------
# Main (somente quando executado como script)
# ---------------------------------------------------------------------------
_family_main() {
  local quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quiet)          quiet=1; shift ;;
      --allow-avx512)   export AI_ALLOW_AVX512=1; shift ;;
      --no-avx512)      export AI_NO_AVX512=1; shift ;;
      --family)         [[ $# -ge 2 ]] || { echo "--family exige valor" >&2; exit 2; }; FORCE_FAMILY="$2"; shift 2 ;;
      -h|--help)
        sed -n '3,30p' "$_self" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
    esac
  done

  read_cpu_env

  if [[ -n "${FORCE_FAMILY:-}" ]]; then
    FAMILY_ID="$FORCE_FAMILY"
    FAMILY_MATCH_REASON="forçada manualmente"
  else
    pick_family "$CPU_MODEL"
  fi
  load_family "$FAMILY_ID"
  compute_isa

  if [[ $quiet -eq 1 ]]; then
    printf 'FAMILY=%s\n' "$FAMILY_ID"
    return 0
  fi

  printf '\n== Família ==\n'
  printf '  CPU:        %s\n' "${CPU_MODEL:-desconhecido}"
  printf '  Família:    %s (%s)\n' "$FAMILY_ID" "$FAMILY_NAME"
  printf '  Reconhecida por: %s\n' "$FAMILY_MATCH_REASON"
  [[ -n "${FAMILY_CPUID_HINT:-}" ]] && printf '  CPUID:      %s\n' "$FAMILY_CPUID_HINT"
  [[ -n "${FAMILY_INHERITS:-}" ]] && printf '  Herda de:   %s\n' "$FAMILY_INHERITS"

  printf '\n== Build (llama.cpp) ==\n'
  printf '  -march:     %s\n' "${FAMILY_MARCH_EFFECTIVE:-<nenhum — usa a ISA detectada>}"
  [[ -n "${FAMILY_MARCH_NOTE:-}" ]] && printf '  Nota:       %s\n' "$FAMILY_MARCH_NOTE"
  printf '  Flags ggml: %s\n' "${FAMILY_GGML_FLAGS:-<nenhuma>}"

  printf '\n== AVX-512 ==\n'
  printf '  Habilitado: %s\n' "$AVX512_ENABLED"
  printf '  Motivo:     %s\n' "$AVX512_REASON"

  [[ -n "${FAMILY_NOTES:-}" ]] && printf '\n== Notas ==\n  %s\n' "$FAMILY_NOTES"

  printf '\nFAMILY=%s\n' "$FAMILY_ID"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  FORCE_FAMILY=""
  _family_main "$@"
fi
