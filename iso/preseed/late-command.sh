#!/bin/sh
#
# iso/preseed/late-command.sh — executado PELO INSTALADOR, já no fim da
# instalação (com o sistema instalado montado em /target).
# -----------------------------------------------------------------------------
# Este arquivo é um TEMPLATE: `iso/build-iso.sh` substitui os marcadores
# (nomes entre arrobas duplas) antes de gravá-lo na ISO.
#
# Serve os DOIS instaladores suportados:
#   * Debian  → debian-installer, chamado por `d-i preseed/late_command`
#   * Ubuntu  → Subiquity/autoinstall, chamado pelo `late-commands:` do
#               autoinstall.yaml, com AI_CURTIN=1 (ver `in_target` abaixo)
#
# O que ele faz:
#   1. Copia o projeto ai-cpu-os (que veio na ISO) para /opt/ai-cpu-os do
#      sistema instalado.
#   2. Registra papel + família escolhidos no momento da criação da ISO.
#   3. Instala e habilita um serviço systemd de PRIMEIRO BOOT, que aplica o
#      tuning e instala o papel no hardware real.
#
# POR QUE APLICAR NO PRIMEIRO BOOT (e não aqui)?
#   * Neste momento o sistema instalado NÃO está em execução: não há systemd
#     ativo, então `systemctl` e o tuning de kernel seriam aplicados "às cegas"
#     num chroot.
#   * Vários ajustes (C-states via cmdline do kernel, governor, huge pages)
#     só fazem sentido com o kernel do sistema instalado rodando.
#   * O papel e a família corretos dependem do HARDWARE REAL — detectá-los
#     aqui seria detectar a máquina de instalação no melhor caso, ou nada no
#     pior.
#   Isso está documentado em docs/ISO.md § "Por que primeiro boot".
#
# Shell POSIX (`sh`): é o que o debian-installer garante. O Subiquity executa
# late-commands via `sh -c`, então o mesmo arquivo serve aos dois.
# -----------------------------------------------------------------------------

set -eu

log() { echo "[ai-cpu-os/iso-late] $*"; }

SRC="/cdrom"
DST="/target/opt/ai-cpu-os"
UNIT="/etc/systemd/system/ai-cpu-os-firstboot.service"

## Nome do modelo embutido na mídia (vazio = a ISO foi gerada com --iso-model none).
## O arquivo correspondente é lido de ${SRC}/models/ e copiado para o alvo AQUI,
## na instalação, para o primeiro boot não precisar de rede para nada disso.
ISO_MODEL_NAME="@@ISO_MODEL@@"
MODEL_DST_DIR="/opt/models"

## Nome do tarball da fonte do llama.cpp embutido na midia (vazio = sem fonte).
## O arquivo e copiado para o alvo e o 1o boot usa `--source` com ele: assim o
## passo mais demorado do 1o boot (compilar o llama.cpp) roda SEM rede, e o que
## sera compilado fica pinado no que veio na midia.
ISO_SOURCE_NAME="@@LLAMA_SRC_NAME@@"
SOURCE_DST="/opt/llama-src.tar.gz"

## Senha do ROOT (hash crypt) — vazia = root continua BLOQUEADO (padrão).
## O autoinstall/Subiquity nao tem campo de root, entao o caminho dos DOIS
## instaladores e aqui: `chpasswd -e` espera um hash crypt (nunca texto puro)
## e o aplica dentro do alvo via in_target/curtin.
ROOT_PASSWORD_HASH="@@ROOT_PASSWORD_HASH@@"

## ---------------------------------------------------------------------------
## Executar um comando DENTRO do sistema instalado.
##   d-i:       `in-target` já faz o chroot.
##   Subiquity: `curtin in-target --` faz o mesmo (chamado com AI_CURTIN=1).
## ---------------------------------------------------------------------------
in_target() {
    if [ "${AI_CURTIN:-0}" = "1" ]; then
        curtin in-target -- "$@"
    else
        in-target "$@"
    fi
}

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
## 2. Papel, família e configuração desta ISO
## ---------------------------------------------------------------------------
## MODEL_FILE vazio significa "sem modelo na mídia": o firstboot.sh então não
## passa --model-file e o sistema sobe sem LLM (o usuário instala um depois).
MODEL_FILE=""
if [ -n "${ISO_MODEL_NAME}" ]; then
    MODEL_FILE="${MODEL_DST_DIR}/${ISO_MODEL_NAME}"
fi

## LLAMA_SRC vazio significa "sem fonte na midia": o firstboot.sh entao nao passa
## --source e o llama-build.sh cai no git clone (precisa de rede).
LLAMA_SRC=""
if [ -n "${ISO_SOURCE_NAME}" ]; then
    LLAMA_SRC="${SOURCE_DST}"
fi

printf 'ROLE=%s\nFAMILY=%s\nFIRSTBOOT_REBOOT=%s\nDISTRO=%s\nISO_BUILD=%s\nMODEL_FILE=%s\nLLAMA_SRC=%s\n' \
    "@@ROLE@@" "@@FAMILY@@" "@@FIRSTBOOT_REBOOT@@" "@@DISTRO@@" "@@ISO_BUILD@@" "${MODEL_FILE}" "${LLAMA_SRC}" \
    > "${DST}/.iso-config"

## ---------------------------------------------------------------------------
## 2-b. Modelo embutido na mídia → /opt/models do alvo
## ---------------------------------------------------------------------------
## Copiamos AGORA (e não no primeiro boot) por dois motivos: a mídia já está
## montada e o destino já está sendo escrito — e um erro de cópia aparece no
## log da instalação, em vez de virar um "modelo ausente" misterioso depois.
if [ -n "${ISO_MODEL_NAME}" ]; then
    if [ -f "${SRC}/models/${ISO_MODEL_NAME}" ]; then
        log "instalando o modelo embutido em ${MODEL_FILE}"
        mkdir -p "/target${MODEL_DST_DIR}"
        if cp "${SRC}/models/${ISO_MODEL_NAME}" "/target${MODEL_DST_DIR}/.part"; then
            mv "/target${MODEL_DST_DIR}/.part" "/target${MODEL_FILE}"
            chown -R llama:llama "/target${MODEL_DST_DIR}" 2>/dev/null || true
            log "modelo instalado: ${MODEL_FILE}"
        else
            log "AVISO: falha ao copiar o modelo; a instalação continua sem ele"
            MODEL_FILE=""
            sed -i "s|^MODEL_FILE=.*|MODEL_FILE=|" "${DST}/.iso-config" 2>/dev/null || true
        fi
    else
        log "AVISO: ${SRC}/models/${ISO_MODEL_NAME} não está na mídia; seguindo sem modelo"
        MODEL_FILE=""
        sed -i "s|^MODEL_FILE=.*|MODEL_FILE=|" "${DST}/.iso-config" 2>/dev/null || true
    fi
else
    log "sem modelo embutido nesta ISO (--iso-model none)"
fi

## ---------------------------------------------------------------------------
## 2-c. Fonte do llama.cpp (embutida) -> /opt/llama-src.tar.gz do alvo
## ---------------------------------------------------------------------------
## Copiamos o TARBALL, sem extrair: o `llama-build.sh --source` ja sabe extrair
## um .tar.gz (inclusive tratando o diretorio de topo do tarball do GitHub). Um
## caminho so, e nada de gastar tempo do instalador descompactando.
if [ -n "${ISO_SOURCE_NAME}" ]; then
    if [ -f "${SRC}/${ISO_SOURCE_NAME}" ]; then
        log "copiando a fonte do llama.cpp para ${SOURCE_DST}"
        if cp "${SRC}/${ISO_SOURCE_NAME}" "/target${SOURCE_DST}.part"; then
            mv "/target${SOURCE_DST}.part" "/target${SOURCE_DST}"
            log "fonte instalada: ${SOURCE_DST}"
        else
            log "AVISO: falha ao copiar a fonte; o 1o boot vai precisar de rede"
            sed -i "s|^LLAMA_SRC=.*|LLAMA_SRC=|" "${DST}/.iso-config" 2>/dev/null || true
        fi
    else
        log "AVISO: ${SRC}/${ISO_SOURCE_NAME} nao esta na midia; seguindo sem fonte"
        sed -i "s|^LLAMA_SRC=.*|LLAMA_SRC=|" "${DST}/.iso-config" 2>/dev/null || true
    fi
else
    log "sem fonte do llama.cpp embutida (--iso-source none)"
fi

## ---------------------------------------------------------------------------
## 2-d. Repositório apt local -> /opt/apt-repo do alvo
## ---------------------------------------------------------------------------
## POR QUE CARREGAR PARA DENTRO DO ALVO: o apt do INSTALADOR roda dentro de um
## chroot no alvo, onde `/cdrom` NÃO está montado — então declarar
## `file:///cdrom/apt-repo` como fonte de instalação faz o `apt-get update`
## falhar com "does not have a Release file" (visto ao bootar a ISO de verdade;
## a suposição do JOURNAL § 5.2 caiu). Copiando o repositório para o disco do
## alvo e apontando-o lá, o PRIMEIRO BOOT (e instalações futuras) usam o
## repositório SEM rede, direto do disco — que é o que a ISO air-gapped precisa.
APT_REPO_SRC="${SRC}/apt-repo"
APT_REPO_DST="/opt/apt-repo"
if [ -d "${APT_REPO_SRC}" ]; then
    log "carregando o repositório apt local para ${APT_REPO_DST}"
    mkdir -p "/target${APT_REPO_DST}"
    if cp -a "${APT_REPO_SRC}/." "/target${APT_REPO_DST}/"; then
        mkdir -p /target/etc/apt/sources.list.d
        printf 'deb [trusted=yes] file://%s ./\n' "${APT_REPO_DST}" \
            > /target/etc/apt/sources.list.d/ai-cpu-os-local.list
        printf 'APT_REPO=%s\n' "${APT_REPO_DST}" >> "${DST}/.iso-config"
        log "repositório local em ${APT_REPO_DST} (fonte gravada no alvo)"
    else
        log "AVISO: falha ao copiar o repositório apt local; resta a rede"
    fi
else
    log "sem repositório apt local nesta ISO (--iso-repo none)"
fi

## ---------------------------------------------------------------------------
## 3. Serviço de primeiro boot
## ---------------------------------------------------------------------------
log "instalando o serviço de primeiro boot"
cp "${SRC}/preseed/firstboot.sh" "${DST}/iso/firstboot.sh"
cp "${SRC}/preseed/ai-cpu-os-firstboot.service" "/target${UNIT}"

# Permissões de execução (alguns arquivos vêm da ISO sem o bit de execução).
chmod 0755 "${DST}/build.sh" "${DST}/detect-hardware.sh" \
           "${DST}/llama-build.sh" "${DST}/iso/firstboot.sh" \
           "${DST}/families/resolve.sh" "${DST}/mods/apply.sh" 2>/dev/null || true
for f in "${DST}"/mods/*/*.sh "${DST}"/roles/*/*.sh "${DST}"/tests/*.sh; do
    [ -f "$f" ] && chmod 0755 "$f" 2>/dev/null || true
done
[ -f "${DST}/roles/inference/shell-ia.py" ] && \
    chmod 0755 "${DST}/roles/inference/shell-ia.py" 2>/dev/null || true

# Sentinela: o serviço só executa enquanto este arquivo existir.
touch "${DST}/.firstboot-pending"

chown -R root:root "${DST}"

# Habilitar o serviço. `systemctl enable` funciona no chroot, mas caímos para
# um symlink manual se algo não estiver disponível — nunca deixamos o serviço
# desabilitado por causa disso.
if in_target systemctl enable ai-cpu-os-firstboot.service >/dev/null 2>&1; then
    log "serviço habilitado via systemctl"
else
    log "systemctl enable indisponível; criando o symlink manualmente"
    mkdir -p /target/etc/systemd/system/multi-user.target.wants
    ln -sf "${UNIT}" \
           "/target/etc/systemd/system/multi-user.target.wants/$(basename "$UNIT")"
fi

## ---------------------------------------------------------------------------
## 4. Aviso no motd
## ---------------------------------------------------------------------------
cat >> /target/etc/issue <<'ISSUE'
  ai-cpu-os: aplicação do tuning no primeiro boot (aguarde alguns minutos)
ISSUE

## ---------------------------------------------------------------------------
## 4-c. Remover fontes de apt apontando para a MÍDIA do sistema instalado
## ---------------------------------------------------------------------------
## A instalação usa o repositório local da mídia (/cdrom/apt-repo) para não
## precisar de rede. Esse caminho deixa de existir depois da instalação — se a
## fonte ficasse no alvo, todo `apt update` reclamaria de um repositório
## inalcançável. Removemos APENAS o que aponta para a mídia: o espelho oficial
## (que é o `primary`) permanece intacto.
APT_REPO_PATH="@@APT_REPO_PATH@@"
if [ -n "${APT_REPO_PATH}" ]; then
    log "removendo fontes de apt que apontam para a mídia (${APT_REPO_PATH})"
    for f in /target/etc/apt/sources.list /target/etc/apt/sources.list.d/*.list /target/etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        if grep -q "${APT_REPO_PATH}" "$f" 2>/dev/null; then
            # .sources (deb822) pode ter a URI num bloco multi-linha; nesses
            # casos é mais seguro remover o arquivo inteiro.
            case "$f" in
                *.sources)
                    case "$(basename "$f")" in
                        ubuntu.sources|debian.sources) : ;;   # normais, não mexer
                        *) rm -f "$f"; log "removido ${f}" ;;
                    esac
                    ;;
                *)
                    cp -a "$f" "${f}.bak" 2>/dev/null || true
                    grep -v "${APT_REPO_PATH}" "${f}.bak" > "$f" 2>/dev/null || true
                    log "limpo ${f} (backup em ${f}.bak)"
                    ;;
            esac
        fi
    done
    if in_target apt-get update >/dev/null 2>&1; then
        log "apt update do alvo OK após a limpeza"
    else
        log "AVISO: apt update no alvo falhou (sem rede agora é esperado); rode depois"
    fi
fi

## ---------------------------------------------------------------------------
## 4-d. Console serial (opcional) — torna o primeiro boot observável sem tela.
## ---------------------------------------------------------------------------
## Sem isto, um teste headless (iso/test-vm.sh) não vê nada do sistema
## instalado: a saída vai para a tela virtual, que ninguém está olhando.
SERIAL_CONSOLE="@@SERIAL_CONSOLE@@"
if [ "${SERIAL_CONSOLE}" = "yes" ]; then
    log "habilitando console serial no sistema instalado (console=ttyS0,115200)"
    if [ -f /target/etc/default/grub ]; then
        if grep -q 'ttyS0' /target/etc/default/grub; then
            log "cmdline já contém ttyS0 (idempotente)"
        else
            cp -a /target/etc/default/grub "/target/etc/default/grub.bak"
            sed -i 's|^\(GRUB_CMDLINE_LINUX_DEFAULT="\)\(.*\)"|\1\2 console=ttyS0,115200 console=tty1"|' \
                /target/etc/default/grub
            if in_target update-grub >/dev/null 2>&1; then
                log "GRUB do alvo regenerado com o console serial"
            else
                log "AVISO: update-grub falhou; rode-o no sistema instalado"
            fi
        fi
        # getty no serial permite logar sem tela (útil para depurar).
        in_target systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1 || \
            log "AVISO: não habilitei serial-getty@ttyS0 (opcional)"
    else
        log "AVISO: /target/etc/default/grub ausente; console serial não configurado"
    fi
fi

## ---------------------------------------------------------------------------
## 5. Registro
## ---------------------------------------------------------------------------
cat > "${DST}/ISO-INFO.txt" <<INFO
ai-cpu-os — instalado a partir de uma ISO customizada
Base do SO: @@DISTRO@@
Build da ISO: @@ISO_BUILD@@
Papel configurado: @@ROLE@@ (auto = detecta no hardware real)
Família configurada: @@FAMILY@@ (auto = detecta no hardware real)
Reboot automático após aplicar: @@FIRSTBOOT_REBOOT@@

O que acontece no primeiro boot:
  1. O serviço ai-cpu-os-firstboot roda automaticamente (leva alguns minutos).
  2. Ele detecta o hardware, aplica as mods do conjunto 'system' e instala o papel.
  3. O log fica em /var/log/ai-cpu-os-firstboot.log
  4. Dependendo do papel, o llama.cpp é compilado (pode levar de 5 a 20 min).
  5. Se o C-states foi alterado, é necessário reiniciar para valer.

Comandos úteis:
  systemctl status ai-cpu-os-firstboot
  cat /var/log/ai-cpu-os-firstboot.log
  cat /var/log/ai-cpu-os-build.log
  bash mods/apply.sh list          # outras modificações portáveis
INFO

## ---------------------------------------------------------------------------
## 3-c. Senha do ROOT (hash crypt) — opcional
## ---------------------------------------------------------------------------
## Sem hash, o root fica BLOQUEADO (padrão e mais seguro). Com hash, o
## `chpasswd -e` aplica a senha DENTRO do alvo — o caminho serve aos DOIS
## instaladores (d-i e Subiquity), porque o autoinstall não tem campo de root.
## O `-e` é o que garante que o valor é um hash crypt, nunca texto puro.
if [ -n "${ROOT_PASSWORD_HASH}" ]; then
    if echo "root:${ROOT_PASSWORD_HASH}" | in_target chpasswd -e; then
        log "senha do root definida (login de root habilitado)"
    else
        log "AVISO: falha ao definir a senha do root (o root segue bloqueado)"
    fi
else
    log "root permanece bloqueado (sem --root-password-hash)"
fi

log "pós-instalação concluído; o ai-cpu-os será aplicado no primeiro boot"

## O `log()` acima vai para o stdout capturado pelo instalador (log do Subiquity),
## NÃO para o console. O iso/test-vm.sh julga pelo CONSOLE SERIAL, então
## repetimos o marcador em /dev/console (que é o ttyS0 quando a ISO é gerada
## com --serial-console). Sem isto o teste headless ficava mudo na instalação.
printf '[ai-cpu-os/iso-late] pós-instalação concluído\n' > /dev/console 2>/dev/null || true