#!/bin/sh
#
# iso/preseed/late-command.sh — executado PELO INSTALADOR, já no fim da
# instalação (ambiente do debian-installer, como root).
# -----------------------------------------------------------------------------
# Este arquivo é um TEMPLATE: `iso/build-iso.sh` substitui os marcadores
# (nomes entre arrobas duplas) antes de gravá-lo na ISO.
#
# O que ele faz:
#   1. Copia o projeto ai-cpu-os (que veio na ISO) para /opt/ai-cpu-os do
#      sistema instalado.
#   2. Registra o perfil escolhido no momento da criação da ISO.
#   3. Instala e habilita um serviço systemd de PRIMEIRO BOOT, que aplica o
#      tuning e instala o perfil no hardware real.
#
# POR QUE APLICAR NO PRIMEIRO BOOT (e não aqui)?
#   * Neste momento o sistema instalado NÃO está em execução: não há systemd
#     ativo, então `systemctl enable/start` e o tuning de kernel seriam
#     aplicados "às cegas" num chroot.
#   * Vários ajustes (C-states via cmdline do kernel, governor, huge pages)
#     só fazem sentido com o kernel do sistema instalado rodando.
#   * O perfil correto depende do HARDWARE REAL — detectá-lo aqui seria
#     detectar a máquina de instalação no melhor caso, ou nada no pior.
#   Isso está documentado em docs/ISO.md § "Por que primeiro boot".
#
# Shell POSIX (`sh`): é o que o debian-installer garante.
# -----------------------------------------------------------------------------

set -eu

log() { echo "[ai-cpu-os/iso-late] $*"; }

SRC="/cdrom"
DST="/target/opt/ai-cpu-os"

log "iniciando o pós-instalação do ai-cpu-os"

if [ ! -d "${SRC}/ai-cpu-os" ]; then
    log "ERRO: ${SRC}/ai-cpu-os não encontrado na mídia. Abortando o pós-instalação."
    # Não usamos `exit 1`: um erro aqui não deve invalidar uma instalação que
    # já deu certo. O sistema sobe sem o ai-cpu-os e o usuário é avisado.
    exit 0
fi

## ---------------------------------------------------------------------------
## 1. Copiar o projeto
## ---------------------------------------------------------------------------
log "copiando o projeto para ${DST}"
mkdir -p "${DST}"
cp -a "${SRC}/ai-cpu-os/." "${DST}/"

## ---------------------------------------------------------------------------
## 2. Perfil e configuração desta ISO
## ---------------------------------------------------------------------------
printf 'PROFILE=%s\nFIRSTBOOT_REBOOT=%s\nISO_BUILD=%s\n' \
    "@@PROFILE@@" "@@FIRSTBOOT_REBOOT@@" "@@ISO_BUILD@@" > "${DST}/.iso-config"

## ---------------------------------------------------------------------------
## 3. Serviço de primeiro boot
## ---------------------------------------------------------------------------
log "instalando o serviço de primeiro boot"
cp "${SRC}/preseed/firstboot.sh" "${DST}/iso/firstboot.sh"
cp "${SRC}/preseed/ai-cpu-os-firstboot.service" \
   /target/etc/systemd/system/ai-cpu-os-firstboot.service

# Permissões de execução (alguns arquivos vêm da ISO sem o bit de execução).
chmod 0755 "${DST}/build.sh" "${DST}/detect-hardware.sh" \
           "${DST}/iso/firstboot.sh" 2>/dev/null || true
for f in "${DST}"/common/*.sh "${DST}"/profiles/*/*.sh "${DST}"/tests/*.sh; do
    [ -f "$f" ] && chmod 0755 "$f" 2>/dev/null || true
done

# Sentinela: o serviço só executa enquanto este arquivo existir.
touch "${DST}/.firstboot-pending"

chown -R root:root "${DST}"

# Habilitar o serviço. `systemctl enable` funciona no chroot, mas cai para um
# symlink manual se algo não estiver disponível — nunca deixamos o serviço
# desabilitado por causa disso.
if in-target systemctl enable ai-cpu-os-firstboot.service >/dev/null 2>&1; then
    log "serviço habilitado via systemctl"
else
    log "systemctl enable indisponível; criando o symlink manualmente"
    mkdir -p /target/etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/ai-cpu-os-firstboot.service \
           /target/etc/systemd/system/multi-user.target.wants/ai-cpu-os-firstboot.service
fi

## ---------------------------------------------------------------------------
## 4. Aviso no motd
## ---------------------------------------------------------------------------
cat >> /target/etc/issue <<'ISSUE'
  ai-cpu-os: aplicação do tuning no primeiro boot (aguarde alguns minutos)
ISSUE

## ---------------------------------------------------------------------------
## 5. Registro
## ---------------------------------------------------------------------------
cat > "${DST}/ISO-INFO.txt" <<INFO
ai-cpu-os — instalado a partir de uma ISO customizada
Build da ISO: @@ISO_BUILD@@
Perfil configurado: @@PROFILE@@ (auto = detecta no hardware real)
Reboot automático após aplicar: @@FIRSTBOOT_REBOOT@@

O que acontece no primeiro boot:
  1. O serviço ai-cpu-os-firstboot roda automaticamente (leva alguns minutos).
  2. Ele detecta o hardware, aplica o tuning e instala o perfil.
  3. O log fica em /var/log/ai-cpu-os-firstboot.log
  4. Dependendo do perfil, o llama.cpp é compilado (pode levar de 5 a 20 min).
  5. Se o C-states foi alterado, é necessário reiniciar para valer.

Comandos úteis:
  systemctl status ai-cpu-os-firstboot
  cat /var/log/ai-cpu-os-firstboot.log
  cat /var/log/ai-cpu-os-build.log
INFO

log "pós-instalação concluído; o ai-cpu-os será aplicado no primeiro boot"
