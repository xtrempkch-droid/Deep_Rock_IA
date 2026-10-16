#!/usr/bin/env bash
#
# iso/write-pendrive.sh — grava a ISO do ai-cpu-os num pendrive, com travas
# -----------------------------------------------------------------------------
# Este é o passo FINAL do projeto: pegar a ISO gerada e transformá-la em um
# pendrive que boota. É também o passo mais perigoso de todos — `dd` num
# dispositivo apaga o que estiver nele, sem aviso e sem desfazer.
#
# O projeto é explícito a respeito (a própria ISO APAGA o disco do alvo):
# quase todo o esforço de segurança aqui é para impedir que você aponte para o
# disco ERRADO. As travas, em ordem de importância:
#
#   1. Recusa o disco que contém `/` (nada sobrescreve o sistema em uso).
#   2. Recusa disco NÃO removível (SATA/NVMe interno) — só passa com
#      --allow-internal, que exige digitar o caminho COMPLETO do dispositivo.
#   3. Recusa dispositivo que não seja disco inteiro (partição, drive de DVD,
#      loop). Um `sr0` (DVD) tem RM=1 e passaria como "removível" se não
#      checássemos o TYPE.
#   4. Recusa se alguma partição do alvo estiver montada.
#   5. Recusa se o arquivo não for uma ISO 9660 (assinatura "CD001").
#   6. Recusa se a ISO não couber no dispositivo.
#   7. AVISA ALTO se o dispositivo for muito maior que a ISO — sinal clássico de
#      "você apontou para o HD externo de 2 TB em vez do pendrive".
#   8. Exige digitar o NOME do dispositivo para confirmar (só `--yes` pula —
#      e `--yes` NUNCA pula as travas 1 a 6).
#   9. Depois de gravar, LÊ DE VOLTA e compara byte a byte (`cmp -n`), provando
#      que o pendrive recebeu exatamente a ISO. Gravar sem conferir é fé, não
#      engenharia.
#
# Opções:
#   --iso PATH        ISO a gravar (padrão: a mais recente em iso/out/*.iso).
#   --device PATH     Dispositivo alvo, ex.: /dev/sdb (SEM número de partição).
#   --list            Lista os dispositivos candidatos (removíveis) e sai.
#   --no-verify       Não lê de volta para conferir (NÃO recomendado).
#   --allow-internal  Permite gravar num disco interno (pede confirmação dupla).
#   --dry-run         Mostra tudo o que faria e sai. Não escreve nada.
#   --yes             Não pede confirmação (automação). Não pula as travas 1-6.
#   -h | --help       Esta ajuda.
#
# Requisitos: dd, cmp, sha256sum, lsblk (util-linux), findmnt.
#   Para gravar de verdade: root (dd num dispositivo exige).
#
# Uso típico:
#   make pendrives                          # o que está plugado?
#   sudo make pendrive DEVICE=/dev/sdb      # grava (pede confirmação)
#   sudo make pendrive DEVICE=/dev/sdb DRY=--dry-run   # só simula
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

ISO_PATH=""
DEVICE=""
LIST_ONLY=0
DO_VERIFY=1
ALLOW_INTERNAL=0
DRY_RUN=0
ASSUME_YES=0

# Preenchidos ao resolver a ISO. Inicializados aqui para que `set -u` não
# reclame se uma função for chamada (ex.: pelo teste) antes da resolução.
ISO_SIZE_BYTES=0
ISO_SIZE_MB=0
ISO_SHA=""

# Tamanho mínimo para desconfiar do alvo: se o dispositivo for maior que
# ISO × este fator, avisamos com força (pendrive típico: 8-64 GB; um HD externo
# de 1-4 TB cai aqui).
readonly SUSPICIOUS_RATIO=8

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"
  C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK"   "$(_ts)" "$*" "$C_RESET"; }
section()   { printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Costura fina para teste (São funções justamente para o teste poder
# substituí-las: `source iso/write-pendrive.sh` + redefinir). Em produção elas
# são as consultas REAIS ao kernel/lsblk — e é isso que o teste do disco da
# raiz exercita, sem stub nenhum.
# ---------------------------------------------------------------------------
dev_is_block_device() { [[ -b "$1" ]]; }
dev_is_whole_disk()   { [[ -d "/sys/block/$(basename "$1")" ]]; }
dev_field()           { lsblk -ndo "$2" "$1" 2>/dev/null | tr -d ' \n'; }
dev_size_bytes()      { lsblk -ndbo SIZE "$1" 2>/dev/null | tr -d ' \n'; }

# Nome (sem /dev/) do disco que contém a raiz. É a trava nº 1.
root_disk_name() {
  local src disk
  src="$(findmnt -no SOURCE / 2>/dev/null || true)"
  [[ -n "$src" ]] || return 0
  disk="$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  if [[ -n "$disk" ]]; then
    printf '%s' "$disk"
  else
    # Sem PKNAME (ex.: a raiz é um dispositivo inteiro): usa o próprio nome.
    basename "$src"
  fi
}

# Alguma partição do dispositivo está montada? (gravar com algo montado
# corrompe o sistema de arquivos EM USO e pode travar a máquina)
dev_is_mounted() {
  local dev="$1" base mounted
  base="$(basename "$dev")"
  mounted="$(findmnt -rno SOURCE 2>/dev/null || true)"
  [[ -n "$mounted" ]] || return 1
  # Cobre /dev/sdb e /dev/sdb1 (e também o formato /dev/mapper/...).
  printf '%s\n' "$mounted" | grep -qE "^/dev/${base}([0-9]+|$)" && return 0
  return 1
}

# É removível? RM=1 **ou** o barramento é de cartão/pendrive.
dev_is_removable() {
  local dev="$1" rm tran
  rm="$(dev_field "$dev" RM)"
  tran="$(dev_field "$dev" TRAN)"
  [[ "$rm" == "1" ]] && return 0
  case "$tran" in
    usb|mmc|sdio) return 0 ;;
  esac
  return 1
}

# A assinatura ISO 9660 fica no byte 32769 (0-based 32768): "CD001".
# Sem esta checagem, gravar um arquivo qualquer "pareceria" funcionar.
is_iso9660() {
  local f="$1" magic
  [[ -f "$f" ]] || return 1
  magic="$(dd if="$f" bs=1 skip=32768 count=5 2>/dev/null || true)"
  [[ "$magic" == "CD001" ]]
}

# ---------------------------------------------------------------------------
# Lista de candidatos
# ---------------------------------------------------------------------------
list_candidates() {
  section "Dispositivos plugados"
  local found=0 name type rm tran size model dev
  while read -r name; do
    [[ -n "$name" ]] || continue
    dev="/dev/${name}"
    type="$(dev_field "$dev" TYPE)"
    [[ "$type" == "disk" ]] || continue
    rm="$(dev_field "$dev" RM)"
    tran="$(dev_field "$dev" TRAN)"
    size="$(lsblk -ndo SIZE "$dev" 2>/dev/null | tr -d ' \n')"
    model="$(lsblk -ndo MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]*$//')"
    if dev_is_removable "$dev"; then
      printf '  %b%s%b  %s  %s  %s\n' "$C_OK" "$dev" "$C_RESET" "$size" "${tran:-?}" "${model:-(sem modelo)}"
      found=1
    else
      printf '  %b%s%b  %s  %s  %s  %b(interno — RECUSADO)%b\n' \
        "$C_ERR" "$dev" "$C_RESET" "$size" "${tran:-?}" "${model:-(sem modelo)}" "$C_WARN" "$C_RESET"
    fi
  done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2 == "disk" {print $1}')

  echo
  if (( found == 0 )); then
    log_warn "Nenhum dispositivo removível encontrado. Plugue o pendrive e repita."
    log_info "(Discos internos aparecem acima marcados como RECUSADOS.)"
  else
    log_info "Use: sudo bash iso/write-pendrive.sh --device /dev/sdX"
  fi
}

# ---------------------------------------------------------------------------
# Travas. Cada uma é uma recusa explícita com o MOTIVO (não um erro genérico).
# ---------------------------------------------------------------------------
validate_target() {
  local dev="$1"
  local name type rm tran size_bytes=0

  [[ -n "$dev" ]] || { log_error "--device é obrigatório (veja --list)."; return 2; }
  [[ "$dev" == /dev/* ]] || { log_error "--device tem de ser um caminho /dev/... (recebi '${dev}')."; return 2; }

  name="$(basename "$dev")"

  # 1. TRAVA MÁXIMA: o disco da raiz. Sem override — de propósito. Vem ANTES da
  # checagem de block device: num ambiente onde o device ainda não existe
  # (ex.: container, ou pendrive não plugado), o NOME já é suficiente para
  # identificar o disco do sistema — e essa trava não pode depender de nada.
  local root_disk
  root_disk="$(root_disk_name)"
  if [[ -n "$root_disk" && "$name" == "$root_disk" ]]; then
    log_error "'${dev}' é o disco que contém o sistema em execução (/)."
    log_error "GRAVAR AQUI DESTRUIRIA A MÁQUINA. Recusado — e não há opção para forçar."
    return 1
  fi

  # 2. Existe e é dispositivo de bloco?
  if ! dev_is_block_device "$dev"; then
    log_error "'${dev}' não é um dispositivo de bloco."
    log_error "Se acabou de plugar, confira o nome com --list."
    return 2
  fi

  type="$(dev_field "$dev" TYPE)"

  # 3. Disco inteiro (não partição, não DVD, não loop).
  if [[ "$type" != "disk" ]] || ! dev_is_whole_disk "$dev"; then
    log_error "'${dev}' não é um DISCO inteiro (tipo detectado: '${type:-?}')."
    if [[ "$type" == "rom" ]]; then
      log_warn "Um drive de DVD reporta-se como removível — mas não é um pendrive."
    elif [[ "$type" == "part" ]]; then
      log_error "Você passou uma PARTIÇÃO. Use o disco, sem o número: /dev/${name%%[0-9]*}"
    fi
    return 1
  fi

  # 4. Não removível.
  if ! dev_is_removable "$dev"; then
    rm="$(dev_field "$dev" RM)"
    tran="$(dev_field "$dev" TRAN)"
    if (( ALLOW_INTERNAL == 0 )); then
      log_error "'${dev}' NÃO é removível (RM=${rm:-?}, barramento='${tran:-?}')."
      log_error "Parece ser um disco INTERNO. Se um pendrive aparecer aqui, prefira"
      log_error "outro dispositivo — alguns adaptadores mentem sobre serem removíveis."
      log_error "Para gravar num disco interno mesmo assim: --allow-internal (e leia o aviso)."
      return 1
    fi
    log_warn "'${dev}' não é removível, mas --allow-internal foi dado (RM=${rm:-?}, TRAN='${tran:-?}')."
  fi

  # 5. Montado?
  if dev_is_mounted "$dev"; then
    log_error "'${dev}' (ou uma partição dele) está MONTADO."
    log_error "Desmonte antes: sudo umount ${dev}*   (e confirme com: findmnt)"
    return 1
  fi

  # 6. Cabe?
  size_bytes="$(dev_size_bytes "$dev")"
  if [[ -n "$size_bytes" ]] && (( size_bytes > 0 )); then
    if (( size_bytes < ISO_SIZE_BYTES )); then
      log_error "A ISO (${ISO_SIZE_MB} MB) NÃO CABE em ${dev} ($(( size_bytes / 1024 / 1024 )) MB)."
      return 1
    fi
    # 7. Desconfiança de proporção: alvo grande demais costuma ser o disco errado.
    if (( size_bytes / ISO_SIZE_BYTES >= SUSPICIOUS_RATIO )); then
      log_warn "${dev} tem $(( size_bytes / 1024 / 1024 / 1024 )) GB e a ISO tem ${ISO_SIZE_MB} MB"
      log_warn "($(( size_bytes / ISO_SIZE_BYTES ))x maior). Confirme que não é um HD de dados!"
    fi
  fi

  return 0
}

# Confirmação: digitar o NOME do dispositivo (ex.: `sdb`). Não é "yes", é o
# nome — obriga a olhar para o que está prestes a ser apagado.
confirm_target() {
  local dev="$1" name ans
  name="$(basename "$dev")"
  if (( ASSUME_YES == 1 )); then
    log_warn "--yes: confirmação pulada. As travas de segurança acima foram verificadas."
    return 0
  fi
  echo
  printf '%b>>> Digite o nome do dispositivo (%s) para CONFIRMAR a gravação: %b' \
    "$C_BOLD" "$name" "$C_RESET"
  read -r ans
  if [[ "$ans" != "$name" ]]; then
    log_error "Não confere (digitado: '${ans}', esperado: '${name}'). Nada foi gravado."
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Gravação + verificação
# ---------------------------------------------------------------------------
write_image() {
  local dev="$1"
  log_info "Gravando ${ISO_PATH} em ${dev} (${ISO_SIZE_MB} MB)…"
  # conv=fsync: o dd só retorna depois que o kernel mandou tudo ao dispositivo.
  # status=progress: dá sinal de vida num processo que pode levar minutos.
  dd if="$ISO_PATH" of="$dev" bs=4M conv=fsync status=progress
  sync
  log_ok "Gravação concluída."
}

verify_image() {
  local dev="$1" ini fim
  section "Verificação (lendo de volta do pendrive)"
  log_info "Comparando os primeiros ${ISO_SIZE_MB} MB do dispositivo com a ISO…"
  log_info "(isto lê o pendrive inteiro: leva o mesmo tempo da gravação)"
  ini="$(date +%s)"

  # `cmp -n BYTES` compara byte a byte e PARA na primeira diferença.
  # Por que não `sha256sum` do dispositivo: o pendrive costuma ser maior que a
  # ISO, e o lixo depois do fim da imagem mudaria o hash. Com -n o escopo é
  # exatamente a imagem.
  #
  # E por que não `dd | head -c`: com `set -o pipefail`, o `head` fecha o pipe e
  # o `dd` morre com SIGPIPE (141) — armadilha já documentada neste projeto.
  if cmp -n "$ISO_SIZE_BYTES" "$ISO_PATH" "$dev"; then
    fim="$(date +%s)"
    log_ok "Verificação OK: o pendrive contém exatamente a ISO ($(( fim - ini ))s)."
    return 0
  fi
  log_error "VERIFICAÇÃO FALHOU: o que está no pendrive difere da ISO."
  log_error "Causas comuns: pendrive falsificado/defeituoso, hub USB com energia ruim,"
  log_error "ou o arquivo foi gravado por outro processo no meio. Grave de novo."
  return 1
}

# ---------------------------------------------------------------------------
# Guarda de `source`
# ---------------------------------------------------------------------------
# O teste (tests/test-write-pendrive.sh) carrega este arquivo para exercitar as
# TRAVAS sem gravar nada — e para isso precisa das funções sem executar o fluxo.
#
# `families/resolve.sh` resolve isso com `if BASH_SOURCE == $0; then main; fi`.
# Aqui o fluxo é linear (e tem um heredoc, que reindentar mudaria), então um
# `return` cedo é mais simples e não mexe no corpo — de propósito: reindentar
# 100+ linhas por estética já introduziu bug neste projeto.
if [[ "${BASH_SOURCE[0]:-}" != "${0}" ]]; then
  return 0
fi

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)             [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; ISO_PATH="$2"; shift 2 ;;
    --device)          [[ $# -ge 2 ]] || { log_error "--device exige valor"; exit 2; }; DEVICE="$2"; shift 2 ;;
    --list)            LIST_ONLY=1; shift ;;
    --no-verify)       DO_VERIFY=0; shift ;;
    --allow-internal)  ALLOW_INTERNAL=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    --yes)             ASSUME_YES=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
  esac
done

for c in dd cmp sha256sum lsblk findmnt; do
  command -v "$c" >/dev/null 2>&1 || { log_error "Ferramenta ausente: ${c}"; exit 1; }
done

if (( LIST_ONLY == 1 )); then
  list_candidates
  exit 0
fi

# ---------------------------------------------------------------------------
# ISO de origem
# ---------------------------------------------------------------------------
section "ISO de origem"

if [[ -z "$ISO_PATH" ]]; then
  # Sem --iso: pega a mais recente de iso/out/. Assim `make pendrive` funciona
  # logo depois de um build, sem copiar caminho.
  ISO_PATH="$(find "${REPO_ROOT}/iso/out" -maxdepth 1 -name '*.iso' -type f -printf '%T@ %p\n' 2>/dev/null \
              | sort -rn | awk 'NR==1 {print $2}')"
  [[ -n "$ISO_PATH" ]] || {
    log_error "Nenhuma ISO em iso/out/. Gere uma primeiro ou use --iso CAMINHO."
    log_error "  sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/vda"
    exit 2
  }
  log_info "Usando a ISO mais recente: ${ISO_PATH}"
fi

[[ -f "$ISO_PATH" ]] || { log_error "ISO não encontrada: ${ISO_PATH}"; exit 2; }
ISO_PATH="$(cd "$(dirname "$ISO_PATH")" && pwd)/$(basename "$ISO_PATH")"

ISO_SIZE_BYTES="$(stat -c %s "$ISO_PATH")"
ISO_SIZE_MB=$(( ISO_SIZE_BYTES / 1024 / 1024 ))

log_info "Arquivo: $(basename "$ISO_PATH") (${ISO_SIZE_MB} MB)"

# 5. É uma ISO 9660 de verdade? (um .gz renomeado para .iso cairia aqui)
if ! is_iso9660 "$ISO_PATH"; then
  log_error "'${ISO_PATH}' NÃO tem a assinatura de ISO 9660 (\"CD001\")."
  log_error "Um arquivo assim não bootaria — verifique se o build terminou."
  exit 1
fi
log_ok "Assinatura ISO 9660 presente (CD001)."

# sha256 da ISO: fica registrado para você comparar com o .sha256 do build.
ISO_SHA="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
log_info "sha256 da ISO: ${ISO_SHA}"

# ---------------------------------------------------------------------------
# Alvo
# ---------------------------------------------------------------------------
if [[ -z "$DEVICE" ]]; then
  section "Nenhum --device informado"
  list_candidates
  exit 2
fi

section "Alvo: ${DEVICE}"
validate_target "$DEVICE" || exit 1

# Resumo do que vai acontecer — antes da confirmação.
cat <<EOF

  ${C_BOLD}O que vai acontecer:${C_RESET}
    ISO:        $(basename "$ISO_PATH")  (${ISO_SIZE_MB} MB, sha256 ${ISO_SHA:0:16}…)
    Dispositivo: ${DEVICE}
    Modelo:      $(lsblk -ndo MODEL "$DEVICE" 2>/dev/null | sed 's/[[:space:]]*$//')
    Tamanho:     $(lsblk -ndo SIZE "$DEVICE" 2>/dev/null | tr -d ' \n')
    Verificação: $([[ $DO_VERIFY -eq 1 ]] && echo "sim (lê de volta e compara)" || echo "NÃO (--no-verify)")

  ${C_ERR}${C_BOLD}⚠  TODO O CONTEÚDO DE ${DEVICE} SERÁ APAGADO.${C_RESET}
  ${C_ERR}${C_BOLD}   Não há desfazer. Confira o dispositivo acima.${C_RESET}

EOF

if (( DRY_RUN == 1 )); then
  log_info "[dry-run] o comando de gravação seria:"
  log_info "  dd if='${ISO_PATH}' of='${DEVICE}' bs=4M conv=fsync status=progress"
  log_info "[dry-run] nada foi gravado."
  exit 0
fi

# Root é exigido para escrever num dispositivo.
if (( EUID != 0 )); then
  log_error "Gravar em ${DEVICE} exige root."
  log_error "Rode: sudo bash iso/write-pendrive.sh --device ${DEVICE}"
  exit 1
fi

confirm_target "$DEVICE" || exit 1

write_image "$DEVICE"

if (( DO_VERIFY == 1 )); then
  verify_image "$DEVICE" || exit 1
fi

section "Pronto"
log_ok "Pendrive gravado e verificado: ${DEVICE}"
log_info "Boote pela mídia e a instalação do ai-cpu-os será automática."
log_info "⚠  A instalação APAGA o disco do computador onde você bootar. Teste em VM antes."
