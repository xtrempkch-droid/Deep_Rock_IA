#!/usr/bin/env bash
#
# tests/test-avx512-policy.sh — prova a POLÍTICA DE AVX-512 das famílias
# -----------------------------------------------------------------------------
# Por que este teste existe: errar a política de AVX-512 nas DUAS direções custa
# caro, e de jeitos diferentes:
#
#   * LIGAR onde não tem  → o binário nasce com instruções que a CPU não executa
#     e o processo morre com SIGILL. É o pior modo de falha: só aparece na
#     máquina de destino, longe do build.
#   * NÃO LIGAR onde tem  → perda silenciosa de desempenho. Tudo "funciona" e
#     ninguém percebe; só os tokens/s ficam menores. Foi este o caso corrigido
#     quando `amd-zen4` (que TEM AVX-512) estava em `never`.
#
# Duas camadas:
#   1. A DECLARAÇÃO (family.conf): quem pode ter AVX-512 diz `auto`; quem não
#      tem diz `never`. É a trava contra SIGILL.
#   2. O COMPORTAMENTO (`resolve.sh` de verdade): em cross-build, a família que
#      tem AVX-512 habilita E passa `-DGGML_AVX512=ON` ao CMake. E `--no-avx512`
#      vence qualquer política.
#
# ⚠️ ARMADILHA JÁ PISADA (leia antes de "simplificar" este teste):
#   NÃO extraia campos com `| grep -q` nem `| grep -m1` dentro de `$( )`.
#   O grep sai no primeiro match, o `resolve.sh` leva **SIGPIPE (141)** e, com
#   `set -o pipefail`, a SUBSTITUIÇÃO DE COMANDO falha — e sob `set -e` o teste
#   MORRE NO MEIO, **sem imprimir nada**. Foi exatamente o que aconteceu aqui:
#   o teste terminava com `rc=141` e saída vazia, parecendo "passou".
#   Por isso capturamos a saída UMA vez numa variável e usamos `case` (nenhum
#   processo, nenhum pipe, nenhuma corrida). Mesma família do `find | head -1`.
#
# Não precisa de hardware: o caminho de cross-build (`AI_ASSUME_FAMILY_ISA=1`)
# usa o que a FAMÍLIA declara, não o /proc/cpuinfo desta máquina.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); if [[ $VERBOSE -eq 1 ]]; then printf '  ok   %s\n' "$*"; fi; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

RESOLVE="families/resolve.sh"
[[ -f "$RESOLVE" ]] || { echo "FALHOU: $RESOLVE não existe" >&2; exit 1; }

# Famílias cujas CPUs TÊM AVX-512 (política 'auto' — decisão do dono,
# 2026-10-16): servidores Intel v5–v9 + Xeon 6 P (Cascade Lake → Granite
# Rapids) e o Zen 4/5. Fora da lista: `generic` (ligado só pelo runtime, sem
# -march próprio) e as famílias AVX2 (haswell/broadwell/zen1–3), que têm de
# ficar em 'never'.
TEM_AVX512=(amd-zen4 amd-zen5 intel-skylake-avx512 intel-cascadelake-sp \
            intel-icelake-sp intel-sapphirerapids-sp intel-emeraldrapids-sp \
            intel-graniterapids-sp)

# Lê FAMILY_AVX512_POLICY de um family.conf (sem source, para não aplicar efeitos).
policy_of() {
  local f="families/$1/family.conf"
  [[ -f "$f" ]] || { printf 'AUSENTE'; return 0; }
  local linha
  linha="$(grep -m1 '^FAMILY_AVX512_POLICY=' "$f" || true)"   # arquivo: sem SIGPIPE
  [[ -n "$linha" ]] || { printf 'AUSENTE'; return 0; }
  linha="${linha#FAMILY_AVX512_POLICY=}"
  printf '%s' "${linha//\"/}"
}

# Roda o resolve.sh e devolve a SAÍDA INTEIRA (sem pipe: zero risco de SIGPIPE).
# $1 = 0|1 (assumir a ISA da família)   $2 = família   $3.. = flags extras
relatorio() {
  local assume="$1" fam="$2"; shift 2
  AI_ASSUME_FAMILY_ISA="$assume" bash "$RESOLVE" --family "$fam" "$@" 2>&1
}

# Extrai "Habilitado: yes|no" do relatório usando `case` (nenhum processo).
avx512_val() {
  case "$1" in
    *"Habilitado: yes"*) printf 'yes' ;;
    *"Habilitado: no"*)  printf 'no' ;;
    *)                   printf '??' ;;
  esac
}

# A flag que MUDA o build, não só o relatório.
tem_flag_avx512() {
  case "$1" in
    *"-DGGML_AVX512=ON"*) return 0 ;;
    *)                    return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 1) Quem NÃO tem AVX-512 tem de estar em `never` (trava contra SIGILL)
# ---------------------------------------------------------------------------
for fam in _base intel-haswell intel-broadwell amd-zen1 amd-zen2 amd-zen3; do
  p="$(policy_of "$fam")"
  if [[ "$p" == "never" ]]; then
    ok "${fam}: política 'never' (não tem AVX-512)"
  else
    bad "${fam}: política '${p}' — esta família NÃO tem AVX-512; ligar causa SIGILL"
  fi
done

# ---------------------------------------------------------------------------
# 2) Quem TEM AVX-512 tem de estar em `auto` (desempenho por padrão)
# ---------------------------------------------------------------------------
for fam in "${TEM_AVX512[@]}" generic; do
  p="$(policy_of "$fam")"
  if [[ "$p" == "auto" ]]; then
    ok "${fam}: política 'auto' (tem AVX-512: liga por padrão)"
  else
    bad "${fam}: política '${p}' — esta família TEM AVX-512 e deveria ligar sozinha"
  fi
done

# ---------------------------------------------------------------------------
# 3) Comportamento REAL: cross-build de quem TEM AVX-512 habilita
# ---------------------------------------------------------------------------
for fam in "${TEM_AVX512[@]}"; do
  rep="$(relatorio 1 "$fam")"
  got="$(avx512_val "$rep")"
  if [[ "$got" == "yes" ]]; then
    ok "${fam}: cross-build HABILITA AVX-512"
  else
    bad "${fam}: cross-build deu '${got}' (esperado yes) — o alvo perderia desempenho"
  fi
  if tem_flag_avx512 "$rep"; then
    ok "${fam}: passa -DGGML_AVX512=ON ao CMake"
  else
    bad "${fam}: diz que ligou, mas não passa -DGGML_AVX512=ON (inconsistente)"
  fi
  # E tem de DIZER de onde veio a verdade (família, não a CPU desta máquina).
  if [[ "$rep" == *"a família declara"* ]]; then
    ok "${fam}: o motivo aponta a FAMÍLIA como fonte da ISA (cross-build)"
  else
    bad "${fam}: o motivo não distingue cross-build de nativo (mensagem ambígua)"
  fi
done

# ---------------------------------------------------------------------------
# 4) Comportamento REAL: quem NÃO tem não habilita nem em cross-build
# ---------------------------------------------------------------------------
for fam in intel-haswell intel-broadwell amd-zen2 amd-zen3; do
  rep="$(relatorio 1 "$fam")"
  got="$(avx512_val "$rep")"
  if [[ "$got" == "no" ]]; then
    ok "${fam}: cross-build NÃO liga AVX-512"
  else
    bad "${fam}: cross-build deu '${got}' (esperado no) — SIGILL no alvo!"
  fi
  if tem_flag_avx512 "$rep"; then
    bad "${fam}: passa -DGGML_AVX512=ON sem ter AVX-512 (SIGILL garantido)"
  else
    ok "${fam}: não passa -DGGML_AVX512=ON (correto)"
  fi
done

# ---------------------------------------------------------------------------
# 5) `--no-avx512` vence a política (o usuário volta atrás sem editar o repo)
# ---------------------------------------------------------------------------
for fam in amd-zen4 intel-skylake-avx512; do
  rep="$(relatorio 1 "$fam" --no-avx512)"
  got="$(avx512_val "$rep")"
  if [[ "$got" == "no" ]]; then
    ok "${fam}: --no-avx512 desliga (vence a política 'auto')"
  else
    bad "${fam}: --no-avx512 NÃO desligou (deu '${got}') — o usuário perderia o controle"
  fi
  if tem_flag_avx512 "$rep"; then
    bad "${fam}: --no-avx512 mas ainda passa -DGGML_AVX512=ON"
  else
    ok "${fam}: --no-avx512 também tira a flag do CMake"
  fi
done

# ---------------------------------------------------------------------------
# 6) O portão de RUNTIME continua sendo a verdade (não basta a família declarar)
# ---------------------------------------------------------------------------
# Sem `--assume-family-isa`, a decisão olha o /proc/cpuinfo DESTA máquina.
if grep -qw avx512f /proc/cpuinfo 2>/dev/null; then
  ok "esta máquina TEM avx512f — o caso 'CPU sem AVX-512' não é testável aqui"
else
  for fam in amd-zen4 intel-skylake-avx512 generic; do
    rep="$(relatorio 0 "$fam")"
    got="$(avx512_val "$rep")"
    if [[ "$got" == "no" ]]; then
      ok "${fam}: nativo nesta CPU (sem avx512f) → NÃO liga (portão de runtime OK)"
    else
      bad "${fam}: ligou AVX-512 numa CPU que não reporta avx512f (SIGILL!)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# 7) A política vem do family.conf — nunca fixa no código
# ---------------------------------------------------------------------------
if grep -qE '^FAMILY_AVX512_POLICY=' families/_base/family.conf; then
  ok "o padrão herdado (_base) declara FAMILY_AVX512_POLICY"
else
  bad "_base não declara a política: uma família nova herdaria algo imprevisível"
fi

# Regra 12 do AGENTS.md: nada de AVX-512 FIXO em código. Duas coisas distintas,
# e a diferença é tudo:
#
#   * `-mavx512*` é flag de COMPILADOR: gera instruções que só existem naquela
#     microarquitetura. Fixa em código = SIGILL garantido em outro hardware.
#   * `-DGGML_AVX512=ON` é a flag do CMake: ela PODE aparecer, mas só atrás do
#     portão `AVX512_ENABLED == yes` (que vem da política da família + runtime).
#
# (A primeira versão deste teste procurava as duas juntas e reprovava o próprio
#  repositório: a linha do CMake É legítima. Cuidado com guarda que casa com o
#  uso correto — é a armadilha do "guarda contra a prosa que o explica".)
# `-e` em vez de `--`: o padrão começa com '-', e a opção `--include` precisa vir
# ANTES dele (escrever `-- '-mavx512' --include=…` faz o grep tratar o
# `--include` como ARQUIVO — foi o que aconteceu na 1ª versão, e o filtro de
# extensão silenciosamente não filtrou nada).
mavx="$(
  grep -rn --include='*.sh' -e '-mavx512' . 2>/dev/null | grep -v '^\./tests/' || true
)"
if [[ -n "$mavx" ]]; then
  bad "flag de compilador '-mavx512' FIXA em script (SIGILL em outro hardware): ${mavx}"
else
  ok "nenhuma flag de compilador '-mavx512' fixa em script (Regra 12)"
fi

n_cmake="$(grep -rc 'DGGML_AVX512=' families/resolve.sh || true)"
if [[ "$n_cmake" == "1" ]]; then
  ok "-DGGML_AVX512 aparece em UM só lugar (um único ponto de decisão)"
else
  bad "-DGGML_AVX512 aparece ${n_cmake}× — decisão espalhada em vários pontos"
fi
if grep -q 'AVX512_ENABLED" == "yes"' families/resolve.sh; then
  ok "a flag do CMake está atrás do portão AVX512_ENABLED (não é incondicional)"
else
  bad "sumiu o portão AVX512_ENABLED: a flag virou incondicional (Regra 12)"
fi

# ---------------------------------------------------------------------------
# 8) Coerência `-march` × AVX-512 (o caso do znver4 com GCC antigo)
# ---------------------------------------------------------------------------
# `-march=znver4` exige GCC >= 13. Com GCC mais antigo o resolve.sh cai para
# `znver3` — que NÃO tem AVX-512 — enquanto as flags do CMake continuam pedindo
# AVX-512. Não é um erro (as flags são o que compila AVX-512, e a CPU alvo tem
# as instruções), mas sem aviso o relatório dizia "AVX-512: yes" com um -mtune
# de geração antiga, o que confunde quem lê o AI-CPU-OS-BUILD.txt.
FAKE_GCC_DIR="$(mktemp -d)"
printf '#!/bin/sh\necho "12.2.0"\n' > "${FAKE_GCC_DIR}/gcc"
chmod +x "${FAKE_GCC_DIR}/gcc"

rep_velho="$(PATH="${FAKE_GCC_DIR}:$PATH" AI_ASSUME_FAMILY_ISA=1 \
             bash "$RESOLVE" --family amd-zen4 2>&1)"
if [[ "$rep_velho" == *"znver3"* ]]; then
  ok "GCC 12: o -march cai para o fallback znver3 (comportamento esperado)"
else
  bad "GCC 12 não caiu para o fallback (o build quebraria no compilador antigo)"
fi
if [[ "$rep_velho" == *"Atenção:"* ]]; then
  ok "GCC 12 + AVX-512 ligado: o relatório AVISA da incoerência do -march"
else
  bad "GCC 12 + AVX-512 ligado sem aviso (relatório diz 'yes' com -mtune antigo)"
fi
# E com GCC novo (o desta máquina, qualquer que seja) não deve haver fallback.
rep_novo="$(AI_ASSUME_FAMILY_ISA=1 bash "$RESOLVE" --family amd-zen4 2>&1)"
if [[ "$rep_novo" == *"znver4"* ]]; then
  ok "com o GCC desta máquina, o znver4 completo é usado (sem fallback)"
else
  ok "GCC desta máquina < 13: o fallback está ativo (a nota explica)"
fi
rm -rf "$FAKE_GCC_DIR"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "avx512: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "avx512: PASS=${PASS} FAIL=${FAIL}"
exit 1
