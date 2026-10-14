#!/usr/bin/env bash
#
# iso/check-iso.sh — confere uma ISO **baixada** (sem xorriso, sem root)
# -----------------------------------------------------------------------------
# POR QUE EXISTE: o `iso/verify-iso.sh` prova o CONTEÚDO da ISO, mas precisa de
# `xorriso` — e quem só quer gravar um pendrive normalmente não tem. Sem ele, a
# única defesa antes de escrever 4 GB num dispositivo é a fé.
#
# Este script lê o arquivo com ferramentas de BASE (`dd`, `od`, `sha256sum`,
# `stat`) e responde às três perguntas que importam ANTES de gravar:
#
#   1. o arquivo está ÍNTEGRO?      → tamanho plausível + SHA256 (se houver);
#   2. é mesmo uma ISO 9660?        → assinatura `CD001` no setor 16;
#   3. é a ISO do ai-cpu-os e ela
#      BOOTA?                       → Volume ID `AI_CPU_OS_*` + MBR `0x55AA`.
#
# O que ele NÃO faz (e o `verify-iso.sh` faz): olhar o que está DENTRO da ISO
# (config de instalação, projeto embutido, marcadores, repositório apt). Aqui é
# só "o download chegou inteiro e é o arquivo certo" — barato, offline, sem
# privilégio e sem `xorriso`. As duas ferramentas são complementares.
#
# Uso típico (máquina sem xorriso):
#   bash iso/check-iso.sh --iso ~/Downloads/ai-cpu-os-ubuntu.iso
#   bash iso/check-iso.sh --iso ARCHIVE.iso --sha256 "$(cat ARCHIVE.iso.sha256)"
#   make iso-check ISO=~/Downloads/ai-cpu-os-ubuntu.iso
#
# Opções:
#   --iso PATH            ISO a conferir (obrigatório).
#   --sha256 SUM|FILE     SHA256 esperado (ou um arquivo `.sha256` para ler).
#                         Se omitido, usa `PATH.sha256` quando existir.
#   --min-size MB         Tamanho mínimo plausível (padrão: 100).
#   --expect-volid PREFIX Prefixo do Volume ID (padrão: AI_CPU_OS).
#   --allow-any-volid     Aceita qualquer Volume ID (útil para uma ISO de
#                         outra origem; ainda confere CD001 e o SHA256).
#   --quiet               Só o resumo.
#   -h | --help           Esta ajuda.
#
# Saída: código 0 se tudo passou; 1 se houver qualquer problema; 2 se o uso
# estiver errado ou o arquivo não existir.
# Requisitos: dd, od, sha256sum, stat (coreutils). Sem root. Sem rede.
# -----------------------------------------------------------------------------

set -euo pipefail

ISO_PATH=""
EXPECT_SHA=""
MIN_SIZE_MB=100
EXPECT_VOLID="AI_CPU_OS"
ANY_VOLID=0
QUIET=0

PASS=0; FAIL=0; WARN=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi
log_info()  { [[ $QUIET -eq 1 ]] && return 0; printf '%b[i]%b %s\n' "$C_INFO" "$C_RESET" "$*"; }
log_warnm() { WARN=$((WARN+1)); printf '  %b[WARN]%b %s\n' "$C_WARN" "$C_RESET" "$*"; }
log_error() { printf '%b[erro]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
section()   { [[ $QUIET -eq 1 ]] && return 0; printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

pass() { PASS=$((PASS+1)); printf '  %b[PASS]%b %s\n' "$C_OK" "$C_RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %b[FAIL]%b %s\n' "$C_ERR" "$C_RESET" "$1"; }

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)             [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; ISO_PATH="$2"; shift 2 ;;
    --sha256)          [[ $# -ge 2 ]] || { log_error "--sha256 exige valor"; exit 2; }; EXPECT_SHA="$2"; shift 2 ;;
    --min-size)        [[ $# -ge 2 ]] || { log_error "--min-size exige valor"; exit 2; }; MIN_SIZE_MB="$2"; shift 2 ;;
    --expect-volid)    [[ $# -ge 2 ]] || { log_error "--expect-volid exige valor"; exit 2; }; EXPECT_VOLID="$2"; shift 2 ;;
    --allow-any-volid) ANY_VOLID=1; shift ;;
    --quiet|-q)        QUIET=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) log_error "Opção desconhecida: $1"; exit 2 ;;
  esac
done

if [[ -z "$ISO_PATH" ]]; then
  log_error "--iso é obrigatório (veja --help)."
  exit 2
fi
if [[ ! -f "$ISO_PATH" ]]; then
  log_error "Arquivo não encontrado: ${ISO_PATH}"
  exit 2
fi

printf '\n%b ai-cpu-os · conferência de ISO baixada %b\n' "$C_BOLD" "$C_RESET"
[[ $QUIET -eq 1 ]] || printf '   arquivo: %s\n' "$ISO_PATH"

# ---------------------------------------------------------------------------
# 1) Integridade: tamanho plausível
# ---------------------------------------------------------------------------
section "Integridade do arquivo"

size_bytes="$(stat -c %s "$ISO_PATH")"
size_mb=$(( size_bytes / 1024 / 1024 ))
min_bytes=$(( MIN_SIZE_MB * 1024 * 1024 ))

log_info "Tamanho: ${size_mb} MB (${size_bytes} bytes)"
if (( size_bytes < min_bytes )); then
  fail "arquivo com ${size_mb} MB — menor que o mínimo de ${MIN_SIZE_MB} MB (download truncado?)"
else
  pass "tamanho plausível (>= ${MIN_SIZE_MB} MB)"
fi

# ---------------------------------------------------------------------------
# 2) SHA256 (do próprio arquivo .sha256, se existir ao lado)
# ---------------------------------------------------------------------------
if [[ -z "$EXPECT_SHA" && -f "${ISO_PATH}.sha256" ]]; then
  # Um arquivo `.sha256` pode ter mais de uma linha; a primeira é a nossa.
  EXPECT_SHA="$(awk '{print $1; exit}' "${ISO_PATH}.sha256" 2>/dev/null || true)"
  [[ -n "$EXPECT_SHA" ]] && log_info "SHA256 esperado lido de ${ISO_PATH}.sha256"
fi
# Aceita também um caminho de arquivo em --sha256.
if [[ -n "$EXPECT_SHA" && -f "$EXPECT_SHA" ]]; then
  EXPECT_SHA="$(awk '{print $1; exit}' "$EXPECT_SHA" 2>/dev/null || true)"
fi

if [[ -z "$EXPECT_SHA" ]]; then
  log_warnm "nenhum SHA256 disponível — não dá para provar que o download está íntegro"
  log_info "O CI publica o .sha256 junto da ISO; baixe os dois (ou use --sha256)."
else
  log_info "Calculando o SHA256 (pode demorar em arquivo grande)…"
  got="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
  if [[ "$got" == "$EXPECT_SHA" ]]; then
    pass "SHA256 confere (${got:0:16}…)"
  else
    fail "SHA256 divergente!"
    log_error "  esperado: ${EXPECT_SHA}"
    log_error "  obtido:   ${got}"
    log_error "Baixe de novo: um arquivo corrompido gera um pendrive que não instala."
  fi
fi

# ---------------------------------------------------------------------------
# 3) É uma ISO 9660? (setor 16 = Primary Volume Descriptor)
# ---------------------------------------------------------------------------
section "Estrutura ISO 9660"

# O Primary Volume Descriptor fica no LBA 16, com setores de 2048 bytes.
# Layout interno: byte 0 = tipo, bytes 1-5 = "CD001", byte 6 = versão,
# bytes 8-39 = System Identifier, bytes 40-71 = Volume Identifier.
PVD="$(mktemp)"
trap 'rm -f "$PVD"' EXIT
if ! dd if="$ISO_PATH" bs=2048 skip=16 count=1 of="$PVD" 2>/dev/null; then
  fail "não consegui ler o setor 16 da ISO"
fi

magic="$(dd if="$PVD" bs=1 skip=1 count=5 2>/dev/null || true)"
if [[ "$magic" == "CD001" ]]; then
  pass "assinatura ISO 9660 presente (CD001 no setor 16)"
else
  fail "não é uma ISO 9660: esperava CD001, achei '${magic}'"
  log_error "O arquivo pode ser um .zip renomeado — o navegador às vezes entrega"
  log_error "o ARTIFACT (zip) em vez do .iso. Descompacte antes de gravar."
fi

volid="$(dd if="$PVD" bs=1 skip=40 count=32 2>/dev/null | tr -d ' ' || true)"
if [[ -n "$volid" ]]; then
  log_info "Volume ID: '${volid}'"
fi
if (( ANY_VOLID == 1 )); then
  log_info "Volume ID não conferido (--allow-any-volid)."
elif [[ "$volid" == ${EXPECT_VOLID}* ]]; then
  pass "Volume ID começa com ${EXPECT_VOLID} (é uma ISO do projeto)"
else
  fail "Volume ID inesperado: '${volid}' (esperado começar com ${EXPECT_VOLID})"
  log_error "Esta não parece uma ISO gerada pelo ai-cpu-os."
  log_error "Se for de outra origem, use --allow-any-volid."
fi

# ---------------------------------------------------------------------------
# 4) Boota? (assinatura de MBR no setor 0)
# ---------------------------------------------------------------------------
section "Capacidade de boot"

# Uma ISO híbrida (que boota por BIOS, e não só por UEFI) traz o MBR válido:
# os dois últimos bytes do setor 0 são 0x55AA. O build preserva os setores de
# boot da ISO oficial, então isso deve estar lá.
mbr="$(dd if="$ISO_PATH" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n' || true)"
if [[ "$mbr" == "55aa" ]]; then
  pass "assinatura de boot presente (MBR 0x55AA no setor 0)"
else
  log_warnm "assinatura de boot (0x55AA) ausente — UEFI pode funcionar, BIOS provavelmente não"
  log_info "A ISO ainda pode bootar por UEFI (é o caso em VMs com OVMF)."
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '%b  PASS=%d  WARN=%d  FAIL=0%b\n' "$C_OK" "$PASS" "$WARN" "$C_RESET"
  log_info "Arquivo conferido. Próximo passo:"
  log_info "  make pendrives                     # o que está plugado?"
  log_info "  sudo make pendrive DEVICE=/dev/sdX # grava (pede confirmação)"
  exit 0
fi
printf '%b  PASS=%d  WARN=%d  FAIL=%d%b\n' "$C_ERR" "$PASS" "$WARN" "$FAIL" "$C_RESET"
log_error "Não grave este arquivo num pendrive antes de resolver o acima."
exit 1
