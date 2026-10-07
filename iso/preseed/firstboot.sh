#!/usr/bin/env bash
#
# iso/preseed/firstboot.sh — aplica o ai-cpu-os no primeiro boot do sistema
# instalado a partir da ISO.
# -----------------------------------------------------------------------------
# Este arquivo é um TEMPLATE: `iso/build-iso.sh` substitui os marcadores
# (nomes entre arrobas duplas) antes de gravá-lo na ISO.
#
# Roda UMA vez, como root, disparado por `ai-cpu-os-firstboot.service`.
# Garantias:
#   * Idempotente: usa a sentinela `.firstboot-pending`; sem ela, sai na hora.
#   * Não deixa o sistema "meio configurado" em silêncio: registra tudo em
#     .firstboot-status e no log, e mantém a sentinela se falhar com erro
#     recuperável (rede), para tentar de novo no próximo boot.
#   * Respeita o `--profile` gravado na ISO (padrão: auto).
#
# Ver docs/ISO.md § "Por que primeiro boot".
# -----------------------------------------------------------------------------

set -euo pipefail

readonly ROOT="/opt/ai-cpu-os"
readonly SENTINEL="${ROOT}/.firstboot-pending"
readonly CONFIG="${ROOT}/.iso-config"
readonly STATUS="${ROOT}/.firstboot-status"
readonly LOG="/var/log/ai-cpu-os-firstboot.log"

# Valores definidos no momento da criação da ISO.
PROFILE="@@PROFILE@@"
FIRSTBOOT_REBOOT="@@FIRSTBOOT_REBOOT@@"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] [firstboot] %s\n' "$(_ts)" "$*"; }

# Espelha tudo em arquivo, além do journal.
exec > >(tee -a "$LOG") 2>&1

log "=== ai-cpu-os: primeiro boot ==="

# ---------------------------------------------------------------------------
# Sentinela: só roda uma vez.
# ---------------------------------------------------------------------------
if [[ ! -f "$SENTINEL" ]]; then
  log "sentinela ${SENTINEL} ausente: nada a fazer (já aplicado)."
  exit 0
fi

if [[ ! -d "$ROOT" || ! -x "${ROOT}/build.sh" ]]; then
  log "ERRO: ${ROOT}/build.sh não encontrado. Abortando."
  echo "ERRO: projeto ausente em ${ROOT}" > "$STATUS"
  exit 1
fi

# ---------------------------------------------------------------------------
# Configuração gravada pela ISO.
# ---------------------------------------------------------------------------
if [[ -r "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  . "$CONFIG"
  PROFILE="${PROFILE:-auto}"
  FIRSTBOOT_REBOOT="${FIRSTBOOT_REBOOT:-no}"
fi

case "$PROFILE" in
  auto|xeon|ryzen) ;;
  *) log "AVISO: perfil '${PROFILE}' inválido; usando 'auto'."; PROFILE="auto" ;;
esac

log "perfil configurado na ISO: ${PROFILE}"
log "reboot automático após aplicar: ${FIRSTBOOT_REBOOT}"

# ---------------------------------------------------------------------------
# Esperar pela rede (best-effort): o perfil xeon clona o llama.cpp.
# ---------------------------------------------------------------------------
wait_for_network() {
  local i
  log "aguardando conectividade com a internet (até ~2 min)..."
  for i in $(seq 1 24); do
    if getent hosts deb.debian.org >/dev/null 2>&1 \
       || curl -fsS --max-time 5 -o /dev/null https://github.com 2>/dev/null; then
      log "rede disponível (tentativa ${i})."
      return 0
    fi
    sleep 5
  done
  log "AVISO: rede não confirmada; tentando prosseguir mesmo assim."
  return 0
}
wait_for_network

# ---------------------------------------------------------------------------
# Aplicar
# ---------------------------------------------------------------------------
log "executando: build.sh --profile ${PROFILE} --yes"
set +e
( cd "$ROOT" && ./build.sh --profile "$PROFILE" --yes )
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "ERRO: build.sh falhou (código ${rc})."
  log "Consulte /var/log/ai-cpu-os-build.log e docs/TROUBLESHOOTING.md."
  cat > "$STATUS" <<EOF
status=failed
rc=${rc}
profile=${PROFILE}
data=$(_ts)
acao=Veja /var/log/ai-cpu-os-firstboot.log e /var/log/ai-cpu-os-build.log.
EOF
  # Mantém a sentinela: tenta de novo no próximo boot (falha pode ser de rede).
  log "sentinela mantida; será tentado de novo no próximo boot."
  exit 1
fi

# ---------------------------------------------------------------------------
# Sucesso: registrar, desarmar o serviço e (opcional) reiniciar.
# ---------------------------------------------------------------------------
log "aplicação concluída com sucesso (perfil ${PROFILE})."

cat > "$STATUS" <<EOF
status=ok
profile=${PROFILE}
data=$(_ts)
nota=Se o C-states foi alterado, reinicie para o tuning valer plenamente.
EOF

# Desarma: remove a sentinela para não rodar de novo.
rm -f "$SENTINEL"

cat > /etc/motd <<'MOTD'
ai-cpu-os: tuning aplicado no primeiro boot.
  - Estado:      cat /opt/ai-cpu-os/.firstboot-status
  - Log:         cat /var/log/ai-cpu-os-firstboot.log
  - Próximos:    docs/TUTORIAL.md § 7 (perfil xeon) ou § 8 (perfil ryzen)
MOTD

# Desabilita o serviço (o ConditionPathExists já impede, mas limpamos o linkset).
systemctl disable ai-cpu-os-firstboot.service >/dev/null 2>&1 || true

log "=== concluído ==="

if [[ "${FIRSTBOOT_REBOOT,,}" == "yes" || "${FIRSTBOOT_REBOOT,,}" == "true" ]]; then
  log "reboot automático habilitado na ISO: reiniciando em 15 s..."
  shutdown -r +0 "ai-cpu-os: aplicado. Reiniciando para aplicar o tuning de C-states." || true
else
  log "Reinicie manualmente quando puder, para o tuning de C-states valer."
fi
