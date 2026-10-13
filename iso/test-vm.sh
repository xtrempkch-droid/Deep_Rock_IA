#!/usr/bin/env bash
#
# iso/test-vm.sh — boota a ISO numa VM e observa a instalação + o 1º boot
# -----------------------------------------------------------------------------
# Este é o teste que o verify-iso.sh NÃO faz: prova que a ISO boota, instala
# sozinha e aplica o ai-cpu-os no primeiro boot.
#
# Como ele observa tudo sem tela: usa **console serial**. O `console=ttyS0`
# é gravado na entrada de boot da ISO *e* no sistema instalado (via
# `--serial-console` no build-iso.sh), então a saída do instalador e do
# `ai-cpu-os-firstboot` aparecem no log do console. O script espera por
# marcadores específicos desse log:
#
#   ISO-LATE  → "[ai-cpu-os/iso-late] pós-instalação concluído"
#   FIRSTBOOT → "aplicação concluída com sucesso"
#   FALHA     → "[firstboot] ERRO" ou "FALHA"/"failed" do instalador
#
# ⚠️ É um teste LONGO: instalar Ubuntu pela rede leva de 10 a 30 min, e o
# primeiro boot compila o llama.cpp (mais 5 a 20 min). Por padrão o script
# espera até 90 min e vai mostrando o progresso. Rode com `--yes`.
#
# Uso:
#   bash iso/test-vm.sh --iso iso/out/ai-cpu-os-ubuntu-20261012.iso --yes
#
# Opções:
#   --iso PATH        ISO a bootar (obrigatório).
#   --ram MB          Memória da VM (padrão: 4096).
#   --cpus N          vCPUs (padrão: 2).
#   --disk-size SIZE  Tamanho do disco virtual (padrão: 30G).
#   --disk PATH       Usa/reutiliza um qcow2 existente.
#   --timeout-min N   Tempo máximo total (padrão: 90).
#   --log PATH        Log do console serial (padrão: iso/out/vm-serial-<data>.log).
#   --boot-mode M     bios (padrão) | uefi  — UEFI exige OVMF instalado.
#   --no-install      Só boota a ISO, sem esperar instalação (smoke de boot).
#   --keep            Não remove a VM/disco no fim.
#   --dry-run         Mostra o comando do qemu e sai (não precisa de qemu).
#   --yes             Não pede confirmação.
#   -h | --help       Esta ajuda.
#
# Requisitos: qemu-system-x86_64, qemu-img. Recomendado: /dev/kvm (sem KVM fica
# MUITO lento, mas o script avisa e continua). OVMF só para --boot-mode uefi.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
ISO_DIR="$SCRIPT_DIR"
readonly ISO_DIR

ISO_PATH=""
RAM=4096
CPUS=2
DISK_SIZE="30G"
DISK_PATH=""
TIMEOUT_MIN=90
SERIAL_LOG=""
BOOT_MODE="bios"
WAIT_INSTALL=1
KEEP=0
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
  sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)          [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; ISO_PATH="$2"; shift 2 ;;
    --ram)          [[ $# -ge 2 ]] || { log_error "--ram exige valor"; exit 2; }; RAM="$2"; shift 2 ;;
    --cpus)         [[ $# -ge 2 ]] || { log_error "--cpus exige valor"; exit 2; }; CPUS="$2"; shift 2 ;;
    --disk-size)    [[ $# -ge 2 ]] || { log_error "--disk-size exige valor"; exit 2; }; DISK_SIZE="$2"; shift 2 ;;
    --disk)         [[ $# -ge 2 ]] || { log_error "--disk exige valor"; exit 2; }; DISK_PATH="$2"; shift 2 ;;
    --timeout-min)  [[ $# -ge 2 ]] || { log_error "--timeout-min exige valor"; exit 2; }; TIMEOUT_MIN="$2"; shift 2 ;;
    --log)          [[ $# -ge 2 ]] || { log_error "--log exige valor"; exit 2; }; SERIAL_LOG="$2"; shift 2 ;;
    --boot-mode)    [[ $# -ge 2 ]] || { log_error "--boot-mode exige valor"; exit 2; }; BOOT_MODE="$2"; shift 2 ;;
    --no-install)   WAIT_INSTALL=0; shift ;;
    --keep)         KEEP=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --yes)          ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
  esac
done

case "$BOOT_MODE" in
  bios|uefi) ;;
  *) log_error "--boot-mode inválido: '${BOOT_MODE}' (use bios ou uefi)."; exit 2 ;;
esac

[[ -n "$ISO_PATH" ]] || { log_error "--iso é obrigatório. Use --help."; exit 2; }
[[ -n "$SERIAL_LOG" ]] || SERIAL_LOG="${ISO_DIR}/out/vm-serial-$(date +%Y%m%d-%H%M).log"

if [[ ! -f "$ISO_PATH" ]]; then
  log_error "ISO não encontrada: ${ISO_PATH}"
  log_error "Gere primeiro: sudo bash iso/build-iso.sh --distro ubuntu --disk /dev/vda"
  exit 2
fi

if [[ $DRY_RUN -eq 0 ]]; then
  local_missing=()
  for c in qemu-system-x86_64 qemu-img; do
    command -v "$c" >/dev/null 2>&1 || local_missing+=("$c")
  done
  if [[ ${#local_missing[@]} -gt 0 ]]; then
    log_error "Ferramentas ausentes: ${local_missing[*]}"
    log_error "Instale com: apt-get install -y qemu-system-x86 qemu-utils"
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# Disco e acelerador
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$SERIAL_LOG")"

if [[ -z "$DISK_PATH" ]]; then
  DISK_PATH="${ISO_DIR}/out/vm-disk-$(date +%Y%m%d-%H%M).qcow2"
fi

ACCEL_ARGS=()
if [[ -w /dev/kvm ]]; then
  ACCEL_ARGS=(-enable-kvm -cpu host)
else
  log_warn "KVM indisponível: a VM vai rodar em emulação (TCG) e será MUITO lenta."
  log_warn "Se for rodar mesmo assim, considere reduzir --ram para 2048."
  ACCEL_ARGS=(-cpu max)
fi

FW_ARGS=()
if [[ "$BOOT_MODE" == "uefi" ]]; then
  OVMF=""
  for cand in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [[ -f "$cand" ]] && { OVMF="$cand"; break; }
  done
  if [[ -z "$OVMF" ]]; then
    log_error "--boot-mode uefi exige OVMF (pacote 'ovmf'). Não encontrei o firmware."
    exit 3
  fi
  FW_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF}")
  log_info "UEFI: ${OVMF}"
fi

# ---------------------------------------------------------------------------
# Espera por um marcador no log serial
# ---------------------------------------------------------------------------
# Retorna 0 quando encontra; 1 no timeout. Vai imprimindo as linhas novas,
# para o usuário ver o progresso em vez de olhar para o vazio.
wait_for_marker() {
  local pattern="$1" deadline_min="$2" description="$3"
  local deadline=$(( $(date +%s) + deadline_min * 60 ))
  local seen=0
  local last_report=0
  while true; do
    if [[ -f "$SERIAL_LOG" ]]; then
      # Mostra o que apareceu desde a última checagem (sem repetir).
      seen_now="$(wc -l < "$SERIAL_LOG")"
      if [[ "$seen_now" -gt "$seen" ]]; then
        sed -n "$((seen + 1)),${seen_now}p" "$SERIAL_LOG" | tail -n 12
        seen="$seen_now"
      fi
      if grep -qE "$pattern" "$SERIAL_LOG"; then
        log_ok "${description}: marcador encontrado."
        return 0
      fi
      # Falha explícita não deve esperar o timeout inteiro.
      if grep -qE '\[firstboot\] ERRO|Erro fatal|install failed|Fatal error' "$SERIAL_LOG"; then
        log_error "Falha detectada no log serial durante '${description}'."
        return 1
      fi
    fi
    if [[ "$(date +%s)" -ge "$deadline" ]]; then
      log_error "Timeout (${deadline_min} min) esperando: ${description}"
      return 1
    fi
    local now
    now="$(date +%s)"
    if [[ $(( now - last_report )) -ge 300 ]]; then
      log_info "ainda esperando ${description}… ($(( (deadline - now) / 60 )) min restantes)"
      last_report="$now"
    fi
    sleep 15
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf '%b' "$C_BOLD"
  printf '=================================================\n'
  printf '   ai-cpu-os · teste de boot da ISO numa VM\n'
  printf '=================================================\n'
  printf '%b' "$C_RESET"

  log_info "ISO:      ${ISO_PATH} ($(du -h "$ISO_PATH" | awk '{print $1}'))"
  log_info "Disco:    ${DISK_PATH} (${DISK_SIZE})"
  log_info "VM:       ${RAM} MB · ${CPUS} vCPU · boot ${BOOT_MODE}"
  log_info "Serial:   ${SERIAL_LOG}"
  log_info "Timeout:  ${TIMEOUT_MIN} min"

  log_warn "A instalação APAGA o disco virtual ${DISK_PATH} (não toca no seu disco real)."
  if [[ $ASSUME_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
    read -r -p "Prosseguir? [s/N] " reply
    [[ "$reply" =~ ^[sSyY]$ ]] || { log_warn "Cancelado."; exit 0; }
  fi

  # Comando do qemu. -display none + -serial file: = tudo no log, nada na tela.
  # -no-reboot: se a VM tentar reiniciar, paramos em vez de ficar em loop.
  local -a qemu_cmd=(
    qemu-system-x86_64
    "${ACCEL_ARGS[@]}"
    "${FW_ARGS[@]}"
    -m "$RAM" -smp "$CPUS"
    -drive "file=${DISK_PATH},if=virtio,format=qcow2"
    -cdrom "$ISO_PATH"
    # `once=d`: o CD (instalador) é o 1º boot; os SEGUINTES usam a ordem
    # normal (c = disco) — é assim que a MESMA VM instala, reinicia e então
    # roda o 1º boot do sistema instalado (onde o `firstboot` aplica o tuning).
    # NÃO usar `-boot d` + `-no-reboot`: o instalador reinicia ao terminar e o
    # `-no-reboot` encerraria o qemu, matando o 1º boot que é justamente o
    # segundo marcador do teste.
    -boot "order=c,once=d"
    -display none
    -serial "file:${SERIAL_LOG}"
    -monitor none
    -netdev "user,id=net0" -device "virtio-net-pci,netdev=net0"
  )

  if [[ $DRY_RUN -eq 1 ]]; then
    section "dry-run"
    log_info "[dry-run] qemu-img create -f qcow2 ${DISK_PATH} ${DISK_SIZE}"
    printf '  %s \\\n' "${qemu_cmd[@]}"
    log_info "[dry-run] esperaria por: ISO-LATE, depois FIRSTBOOT (ou timeout)"
    log_info "Nada foi executado. Rode sem --dry-run para valer."
    return 0
  fi

  if [[ ! -f "$DISK_PATH" ]]; then
    qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null
    log_ok "Disco virtual criado."
  else
    log_info "Reutilizando o disco existente (para um teste limpo, apague-o)."
  fi

  : > "$SERIAL_LOG"

  # Inicia o qemu em background; o script conduz pela leitura do log serial.
  qemu-system-x86_64 \
    "${ACCEL_ARGS[@]}" "${FW_ARGS[@]}" \
    -m "$RAM" -smp "$CPUS" \
    -drive "file=${DISK_PATH},if=virtio,format=qcow2" \
    -cdrom "$ISO_PATH" -boot "order=c,once=d" \
    -display none -serial "file:${SERIAL_LOG}" -monitor none \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 &
  QEMU_PID=$!
  log_info "qemu iniciado (pid ${QEMU_PID}). Console serial em ${SERIAL_LOG}."

  # Garante que a VM morre quando o script sair (inclusive por timeout).
  cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      log_info "Encerrando a VM (pid ${QEMU_PID})…"
      kill "$QEMU_PID" 2>/dev/null || true
      wait "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ $KEEP -eq 0 && -f "$DISK_PATH" ]]; then
      log_info "Removendo ${DISK_PATH} (use --keep para mantê-lo)."
      rm -f "$DISK_PATH" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  local rc=0
  if [[ $WAIT_INSTALL -eq 1 ]]; then
    # 1) O instalador rodou e o late-command copiou o projeto?
    section "Instalação"
    if ! wait_for_marker 'ai-cpu-os/iso-late\] pós-instalação concluído' \
                         "$TIMEOUT_MIN" "late-command (instalação)"; then
      rc=1
    fi

    # 2) O primeiro boot aplicou o ai-cpu-os?
    if [[ $rc -eq 0 ]]; then
      section "Primeiro boot"
      if ! wait_for_marker 'aplicação concluída com sucesso' \
                           "$TIMEOUT_MIN" "firstboot (aplicação do ai-cpu-os)"; then
        rc=1
      fi
    fi
  else
    section "Boot da ISO (sem esperar instalação)"
    if ! wait_for_marker 'casper|Subiquity|ai-cpu-os|isolinux|SYSLINUX' 15 "sinal de boot"; then
      log_warn "Não vi sinal claro de boot. Confira ${SERIAL_LOG}."
      rc=1
    fi
  fi

  section "Resumo"
  if [[ $rc -eq 0 ]]; then
    log_ok "Teste de VM: OK — a ISO bootou, instalou e aplicou o ai-cpu-os."
    log_info "Log completo: ${SERIAL_LOG}"
    log_info "Cole os pontos relevantes no Bloco M de docs/VALIDATION.md."
  else
    log_error "Teste de VM: FALHOU (ou não terminou a tempo)."
    log_error "Diagnóstico no log: ${SERIAL_LOG}"
    log_info "Dicas:"
    log_info "  - Sem marcador de late-command → o instalador não achou a config"
    log_info "    (veja /autoinstall.yaml no Bloco M.3 ou rode verify-iso.sh)."
    log_info "  - Sem marcador de firstboot → veja se o console=ttyS0 entrou na"
    log_info "    cmdline do sistema instalado (gere a ISO com --serial-console)."
    log_info "  - Aumente --timeout-min: compilar o llama.cpp leva 5-20 min."
  fi
  return $rc
}

main "$@"
