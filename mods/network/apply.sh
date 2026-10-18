#!/usr/bin/env bash
#
# mods/network/apply.sh — rede persistente (netplan) do ai-cpu-os
# -----------------------------------------------------------------------------
# POR QUE ESTA MOD EXISTE
#   Uma instalação feita com uma ISO antiga subia SEM rede: o Subiquity usa DHCP
#   para si mesmo, mas **não grava configuração persistente no alvo** quando o
#   autoinstall não tem a chave `network:`. O sintoma é a placa DOWN até alguém
#   rodar `ip link set … up` + `dhclient …` — em todo boot.
#
#   Esta mod escreve a configuração no sistema INSTALADO. É o mesmo conteúdo que
#   o `iso/build-iso.sh` passou a embutir na mídia (uma fonte de verdade só),
#   servindo para consertar máquinas que já estão no chão.
#
# O QUE ELA FAZ
#   1. Grava /etc/netplan/99-ai-cpu-os.yaml (0600 — é o que o netplan espera).
#   2. Move o netplan deixado pelo instalador/cloud-init para *.ai-cpu-os.bak:
#      duas definições do MESMO adaptador fazem o netplan RECUSAR a configuração.
#   3. Grava /etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg
#      (`network: {config: disabled}`) para o cloud-init não reescrever nada.
#   4. Valida com `netplan generate` e, se for o sistema em execução, aplica.
#
# Uso:
#   sudo bash apply.sh                        # DHCP em en*/eth* (padrão)
#   sudo bash apply.sh --interface enp5s0     # DHCP só nessa placa
#   sudo bash apply.sh --mode static --ip 192.168.1.50/24 --gateway 192.168.1.1
#   sudo bash apply.sh --root /mnt/alvo       # prepara OUTRO sistema (chroot-like)
#   sudo bash apply.sh --dry-run
#
# Flags: --mode auto|dhcp|static|none | --interface NOME | --ip IP[/N]
#        | --gateway IP | --dns "A,B" | --root DIR | --dry-run | --yes
#
# `--root DIR` existe para TESTE (e para preparar um disco montado): nada é
# executado no sistema em execução, só arquivos são escritos sob DIR.
#
# Idempotente: rodar duas vezes não muda nada e não faz backup à toa.
# -----------------------------------------------------------------------------

set -euo pipefail

MODE="auto"
IFACE=""
IP=""
GATEWAY=""
DNS="1.1.1.1,8.8.8.8"
TARGET_ROOT="/"
DRY_RUN=0

readonly NETPLAN_NAME="99-ai-cpu-os.yaml"
readonly CLOUD_INIT_NAME="99-ai-cpu-os-disable-network.cfg"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
log_info()  { printf '%b[INFO ] %s%b\n' "$C_INFO" "$*" "$C_RESET"; }
log_warn()  { printf '%b[WARN ] %s%b\n' "$C_WARN" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[ERROR] %s%b\n' "$C_ERR" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[OK   ] %s%b\n' "$C_OK" "$*" "$C_RESET"; }

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      [[ $# -ge 2 ]] || { log_error "--mode exige valor"; exit 2; }; MODE="$2"; shift 2 ;;
    --interface) [[ $# -ge 2 ]] || { log_error "--interface exige valor"; exit 2; }; IFACE="$2"; shift 2 ;;
    --ip)        [[ $# -ge 2 ]] || { log_error "--ip exige valor"; exit 2; }; IP="$2"; shift 2 ;;
    --gateway)   [[ $# -ge 2 ]] || { log_error "--gateway exige valor"; exit 2; }; GATEWAY="$2"; shift 2 ;;
    --dns)       [[ $# -ge 2 ]] || { log_error "--dns exige valor"; exit 2; }; DNS="$2"; shift 2 ;;
    --root)      [[ $# -ge 2 ]] || { log_error "--root exige valor"; exit 2; }; TARGET_ROOT="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --yes)       shift ;;   # aceito por compatibilidade: esta mod não pede confirmação
    -h|--help)   usage; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validação (o valor vai para um YAML que o netplan lê no boot; um erro aqui
# deixaria a máquina SEM REDE — o oposto do objetivo)
# ---------------------------------------------------------------------------
RE_IPV4='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
RE_IFACE='^[A-Za-z0-9_.:-]+$'

case "$MODE" in
  auto|dhcp|static|none) ;;
  *) log_error "Modo inválido: '${MODE}' (use auto, dhcp, static ou none)."; exit 2 ;;
esac

if [[ -n "$IFACE" ]] && ! [[ "$IFACE" =~ $RE_IFACE ]]; then
  log_error "Interface inválida: '${IFACE}' (esperado algo como enp5s0)."; exit 2
fi

if [[ "$MODE" == "static" ]]; then
  [[ -n "$IP" ]]      || { log_error "--mode static exige --ip."; exit 2; }
  [[ -n "$GATEWAY" ]] || { log_error "--mode static exige --gateway."; exit 2; }
  ADDR="${IP%%/*}"
  PREFIX="${IP##*/}"
  [[ "$IP" == */* ]] || PREFIX="24"
  [[ "$ADDR" =~ $RE_IPV4 ]] || { log_error "IP inválido: '${IP}'."; exit 2; }
  [[ "$GATEWAY" =~ $RE_IPV4 ]] || { log_error "Gateway inválido: '${GATEWAY}'."; exit 2; }
  [[ "$PREFIX" =~ ^[0-9]{1,2}$ ]] || { log_error "Prefixo inválido: '${PREFIX}'."; exit 2; }
  (( 10#$PREFIX >= 1 && 10#$PREFIX <= 32 )) || { log_error "Prefixo fora de 1..32: '${PREFIX}'."; exit 2; }
fi

if [[ $DRY_RUN -eq 0 && "${EUID:-$(id -u)}" -ne 0 && "$TARGET_ROOT" == "/" ]]; then
  log_error "Precisa de root. Use: sudo bash $0"
  exit 1
fi

# Normaliza o root (sem barra final) para montar caminhos previsíveis.
ROOT="${TARGET_ROOT%/}"
[[ -z "$ROOT" ]] && ROOT=""

NETPLAN_DIR="${ROOT}/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/${NETPLAN_NAME}"
CLOUD_DIR="${ROOT}/etc/cloud/cloud.cfg.d"
CLOUD_FILE="${CLOUD_DIR}/${CLOUD_INIT_NAME}"

log_info "=== mod: network (modo ${MODE}${ROOT:+, root=${ROOT}}) ==="

# ---------------------------------------------------------------------------
# 1. O netplan (mesmo formato do build-iso.sh)
# ---------------------------------------------------------------------------
netplan_body() {
  printf 'network:\n'
  printf '  version: 2\n'
  printf '  renderer: networkd\n'
  printf '  ethernets:\n'

  if [[ "$MODE" == "static" ]]; then
    local dns_yaml
    dns_yaml="$(printf '%s' "$DNS" | sed -e 's/,/, /g')"
    if [[ -n "$IFACE" ]]; then
      printf '    %s:\n' "$IFACE"
    else
      printf '    lan:\n'
      printf '      match:\n'
      printf '        name: "en*"\n'
    fi
    printf '      addresses: [%s/%s]\n' "$ADDR" "$PREFIX"
    printf '      routes:\n'
    printf '        - to: default\n'
    printf '          via: %s\n' "$GATEWAY"
    printf '      nameservers:\n'
    printf '        addresses: [%s]\n' "$dns_yaml"
    printf '      optional: true\n'
    return 0
  fi

  if [[ -n "$IFACE" ]]; then
    printf '    %s:\n' "$IFACE"
    printf '      dhcp4: true\n'
    printf '      dhcp6: false\n'
    printf '      optional: true\n'
  else
    # `optional: true` evita o boot ficar esperando uma placa sem cabo.
    local id
    for id in en eth; do
      printf '    all-%s:\n' "$id"
      printf '      match:\n'
      printf '        name: "%s*"\n' "$id"
      printf '      dhcp4: true\n'
      printf '      dhcp6: false\n'
      printf '      optional: true\n'
    done
  fi
}

write_if_changed() {
  local path="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  chmod 0600 "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    log_info "Sem alterações em ${path} (idempotente)."
    rm -f "$tmp"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] escreveria ${path}:"
    sed 's/^/    | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -d -m 0755 "$(dirname "$path")"
  [[ -f "$path" ]] && cp -a "$path" "${path}.bak.$(date +%s)"
  install -m 0600 "$tmp" "$path"
  rm -f "$tmp"
  log_ok "Escrito ${path}"
}

if [[ "$MODE" == "none" ]]; then
  log_warn "--mode none: nada será gravado. A placa pode subir DESLIGADA."
  log_info "Se a intenção é deixar o instalador decidir, use --mode auto."
else
  netplan_body | write_if_changed "$NETPLAN_FILE"
fi

# ---------------------------------------------------------------------------
# 2. Tirar o netplan do instalador/cloud-init do caminho
# ---------------------------------------------------------------------------
# Duas definições do MESMO adaptador fazem o netplan abortar com
# "Conflicting network definitions" — e o sistema fica sem rede, exatamente o
# que esta mod existe para evitar.
if [[ $DRY_RUN -eq 0 ]]; then
  for f in \
    "${NETPLAN_DIR}/00-installer-config.yaml" \
    "${NETPLAN_DIR}/50-cloud-init.yaml" \
    "${NETPLAN_DIR}/01-netcfg.yaml"; do
    if [[ -f "$f" ]]; then
      mv "$f" "${f}.ai-cpu-os.bak"
      log_info "netplan: $(basename "$f") movido para .ai-cpu-os.bak"
    fi
  done
else
  log_info "[dry-run] moveria netplan do instalador/cloud-init para .ai-cpu-os.bak"
fi

# ---------------------------------------------------------------------------
# 3. cloud-init não mexe mais na rede
# ---------------------------------------------------------------------------
# Sem isto, o cloud-init pode reescrever o netplan no boot seguinte e desfazer
# tudo. `{config: disabled}` é a forma documentada de desligar só a rede.
if [[ "$MODE" != "none" ]]; then
  printf 'network: {config: disabled}\n' | write_if_changed "$CLOUD_FILE"
fi

# ---------------------------------------------------------------------------
# 4. Validar (e aplicar, quando é o sistema em execução)
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] validaria com 'netplan generate' e aplicaria com 'netplan apply'"
  log_ok "mod network simulada (nada foi alterado)."
  exit 0
fi

if [[ -n "$ROOT" ]]; then
  log_info "Root alternativo (${ROOT}): não gero/aplico no sistema em execução."
  log_info "No primeiro boot do alvo, o netplan lê ${NETPLAN_FILE} sozinho."
  log_ok "mod network aplicada em ${ROOT}."
  exit 0
fi

if command -v netplan >/dev/null 2>&1; then
  if netplan generate; then
    log_ok "netplan generate: configuração válida."
  else
    log_error "netplan generate REPROVOU a configuração — não vou aplicar (a rede já está funcionando; aplicar algo inválido a derrubaria)."
    log_error "Diagnóstico: sudo netplan generate --debug"
    exit 1
  fi
  if netplan apply; then
    log_ok "netplan apply: rede aplicada."
  else
    log_warn "netplan apply falhou. O arquivo está no lugar e valerá no próximo boot."
    log_warn "Diagnóstico: sudo netplan apply --debug"
  fi
else
  log_warn "netplan ausente: arquivo gravado, mas não pude validar/aplicar."
  log_warn "Instale (apt install netplan.io) ou reinicie — o boot aplica a config."
fi

log_ok "mod network aplicada. Verifique com: ip -br addr"
log_info "Se a placa continuar sem IP, veja docs/TROUBLESHOOTING.md ('sobe sem rede')."
