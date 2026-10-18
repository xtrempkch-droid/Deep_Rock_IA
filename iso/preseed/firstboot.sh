#!/usr/bin/env bash
#
# iso/preseed/firstboot.sh — aplica o ai-cpu-os no primeiro boot do sistema
# instalado a partir da ISO (Debian **ou** Ubuntu).
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
#   * Respeita o papel/família gravados na ISO (padrão: auto/auto).
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
ROLE="@@ROLE@@"
FAMILY="@@FAMILY@@"
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
  ROLE="${ROLE:-auto}"
  FAMILY="${FAMILY:-auto}"
  FIRSTBOOT_REBOOT="${FIRSTBOOT_REBOOT:-no}"
  # Modelo já copiado para /opt/models pelo late-command (ISO air-gapped).
  # Vazio = a ISO não trouxe modelo; ninguém baixa nada daqui.
  MODEL_FILE="${MODEL_FILE:-}"
  # Fonte do llama.cpp já copiada para /opt/llama-src.tar.gz pelo late-command.
  # Vazio = a ISO não trouxe fonte; nesse caso o build vai precisar de rede.
  LLAMA_SRC="${LLAMA_SRC:-}"
fi

case "$ROLE" in
  auto|inference|builder) ;;
  # Compatibilidade com ISOs geradas antes da refatoração (perfil xeon/ryzen).
  xeon)  ROLE="inference" ;;
  ryzen) ROLE="builder" ;;
  *) log "AVISO: papel '${ROLE}' inválido; usando 'auto'."; ROLE="auto" ;;
esac

log "papel configurado na ISO: ${ROLE}"
log "família configurada na ISO: ${FAMILY}"
log "reboot automático após aplicar: ${FIRSTBOOT_REBOOT}"

# ---------------------------------------------------------------------------
# Modelo embutido na mídia (opcional)
# ---------------------------------------------------------------------------
# O late-command já copiou o .gguf para /opt/models. Repassamos por variável de
# ambiente (mesmo padrão do AI_FAMILY) para o papel instalar SEM baixar nada —
# é o que torna o caminho air-gapped possível.
if [[ -n "$MODEL_FILE" ]]; then
  if [[ -f "$MODEL_FILE" ]]; then
    export AI_MODEL_FILE="$MODEL_FILE"
    log "modelo local: ${MODEL_FILE} (será usado sem rede)"
  else
    log "AVISO: MODEL_FILE=${MODEL_FILE} não existe; seguindo sem modelo."
    MODEL_FILE=""
  fi
else
  log "nenhum modelo embutido nesta ISO (o alvo subirá sem LLM)."
fi

# ---------------------------------------------------------------------------
# Fonte do llama.cpp embutida na mídia (opcional)
# ---------------------------------------------------------------------------
# Exportamos AI_LLAMA_SOURCE (mesmo padrão do AI_FAMILY/AI_MODEL_FILE) e o
# `llama-build.sh` a usa como padrão de `--source`. Isto é o que fecha o
# air-gapped: o passo mais demorado do primeiro boot (compilar o llama.cpp)
# deixa de precisar de internet, e compila EXATAMENTE o que veio na mídia.
if [[ -n "$LLAMA_SRC" ]]; then
  if [[ -f "$LLAMA_SRC" ]]; then
    export AI_LLAMA_SOURCE="$LLAMA_SRC"
    log "fonte local do llama.cpp: ${LLAMA_SRC} (compilação sem rede)"
  else
    log "AVISO: LLAMA_SRC=${LLAMA_SRC} não existe; o build vai clonar do GitHub."
    LLAMA_SRC=""
  fi
else
  log "nenhuma fonte embutida nesta ISO: o build vai clonar o llama.cpp (precisa de rede)."
fi

# ---------------------------------------------------------------------------
# Esperar pela rede (best-effort): o papel 'inference' clona o llama.cpp.
# ---------------------------------------------------------------------------
wait_for_network() {
  local i
  log "aguardando conectividade com a internet (até ~2 min)..."
  for i in $(seq 1 24); do
    if getent hosts archive.ubuntu.com >/dev/null 2>&1 \
       || getent hosts deb.debian.org >/dev/null 2>&1 \
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
log "executando: build.sh --role ${ROLE} --family ${FAMILY} --yes"
set +e
( cd "$ROOT" && ./build.sh --role "$ROLE" --family "$FAMILY" --yes )
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log "ERRO: build.sh falhou (código ${rc})."
  log "Consulte /var/log/ai-cpu-os-build.log e docs/TROUBLESHOOTING.md."
  cat > "$STATUS" <<EOF
status=failed
rc=${rc}
role=${ROLE}
family=${FAMILY}
data=$(_ts)
acao=Veja /var/log/ai-cpu-os-firstboot.log e /var/log/ai-cpu-os-build.log.
EOF
  # Mantém a sentinela: tenta de novo no próximo boot (falha pode ser de rede).
  log "sentinela mantida; será tentado de novo no próximo boot."
  sync   # o status precisa sobreviver a um desligamento logo depois
  exit 1
fi

# ---------------------------------------------------------------------------
# Sucesso: registrar, desarmar o serviço e (opcional) reiniciar.
# ---------------------------------------------------------------------------
log "aplicação concluída com sucesso (papel ${ROLE}, família ${FAMILY})."

cat > "$STATUS" <<EOF
status=ok
role=${ROLE}
family=${FAMILY}
data=$(_ts)
nota=Se o C-states foi alterado, reinicie para o tuning valer plenamente.
EOF

# Ordem deliberada: o status tem de estar DURÁVEL antes de a sentinela sumir.
# Se a sentinela desaparecesse primeiro e faltasse energia, o sistema ficaria
# "aplicado" com um `.firstboot-status` vazio — sem nada dizendo o que houve.
sync

# Desarma: remove a sentinela para não rodar de novo.
rm -f "$SENTINEL"
sync
cat > /etc/motd <<'MOTD'
ai-cpu-os: tuning aplicado no primeiro boot.
  - Estado:      cat /opt/ai-cpu-os/.firstboot-status
  - Log:         cat /var/log/ai-cpu-os-firstboot.log
  - Mods:        bash /opt/ai-cpu-os/mods/apply.sh list
  - Próximos:    docs/TUTORIAL.md
MOTD

# Desabilita o serviço (o ConditionPathExists já impede, mas limpamos o linkset).
systemctl disable ai-cpu-os-firstboot.service >/dev/null 2>&1 || true

log "=== concluído ==="

# `sync` DELIBERADO ANTES DE SAIR. O primeiro boot é o momento em que mais
# arquivos nascem (binários do llama.cpp, units, /etc/default, o próprio
# status). Sem o flush explícito, um desligamento abrupto logo depois — queda
# de energia num servidor, ou o `kill` do qemu no iso/test-vm.sh — deixa
# arquivos com **0 byte** no disco (ext4 com alocação postergada + cache
# writeback do qemu). Visto na prática (sessão #29): `llama-server`,
# `ai-server.service` e `.firstboot-status` existiam com tamanho zero, e um
# unit vazio é interpretado pelo systemd como **masked**.
sync

# Reboot automático opcional (é o que faz a cmdline de C-states valer).
if [[ "${FIRSTBOOT_REBOOT,,}" == "yes" || "${FIRSTBOOT_REBOOT,,}" == "true" ]]; then
  log "reboot automático habilitado na ISO: reiniciando em 15 s..."
  shutdown -r +0 "ai-cpu-os: aplicado. Reiniciando para aplicar o tuning de C-states." || true
else
  log "Reinicie manualmente quando puder, para o tuning de C-states valer."
fi
