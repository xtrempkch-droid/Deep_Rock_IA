#!/bin/sh
#
# iso/common/late-command.sh — executado PELO INSTALADOR, já no fim da
# instalação (com o sistema instalado montado em /target).
# -----------------------------------------------------------------------------
# Este arquivo é um TEMPLATE: `iso/build-iso.sh` substitui os marcadores
# (nomes entre arrobas duplas) antes de gravá-lo na ISO.
#
# Base ÚNICA (ADR-001): **Ubuntu Server**. O instalador é o Subiquity, que
# chama este script pelo `late-commands:` do autoinstall.yaml com AI_CURTIN=1
# (ver `in_target` abaixo).
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
# Shell POSIX (`sh`): o Subiquity executa late-commands via `sh -c`. Mantemos
# POSIX por disciplina (e porque o CI roda `sh -n`), não por causa do d-i.
# -----------------------------------------------------------------------------

set -eu

log() { echo "[ai-cpu-os/iso-late] $*"; }

## Se algo falhar, o console serial precisa DIZER isso. Sem o trap, um erro
## aqui só aparece no log do instalador (tty4) e o sintoma visível é o genérico
## "failed to run late-command" (sessão #35).
rc=0   # só para o shellcheck: o trap abaixo é quem atribui, em tempo de saída
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
        printf "[ai-cpu-os/iso-late] ERRO: falhou com exit %s (veja o log do instalador em tty4)\n" "$rc" > /dev/console 2>/dev/null || true
      fi' EXIT

## Onde está o projeto? No Ubuntu a mídia está em /cdrom. Procuramos também
## nos outros pontos de montagem conhecidos: depender de um caminho fixo é
## frágil (um teste em VM mostrou montagens diferentes entre cenários).
SRC=""
for _cand in /cdrom /media/cdrom /hd-media /media/usb; do
    if [ -d "${_cand}/ai-cpu-os" ]; then
        SRC="${_cand}"
        break
    fi
done
[ -n "${SRC}" ] || SRC="/cdrom"   # mantém a mensagem de erro apontando o lugar esperado
DST="/target/opt/ai-cpu-os"
UNIT="/etc/systemd/system/ai-cpu-os-firstboot.service"

## Nome do modelo embutido na mídia (vazio = a ISO foi gerada com --iso-model none).
## O arquivo correspondente é lido de ${SRC}/models/ e copiado para o alvo AQUI,
## na instalação, para o primeiro boot não precisar de rede para nada disso.
## ATENÇÃO ao tipo de aspas: estes valores são LITERAIS vindos do build. Aspas
## duplas fariam o shell EXPANDIR o que estiver dentro — e um hash crypt sempre
## tem `$`. Foi exatamente assim que a ISO Debian parou de instalar sozinha:
## `ROOT_PASSWORD_HASH="$6$sal$hash"` virava a expansão de `$6` e, sob `set -u`,
## o script morria com exit 2 antes de copiar qualquer arquivo (sessão #35).
ISO_MODEL_NAME='@@ISO_MODEL@@'
MODEL_DST_DIR="/opt/models"

## Nome do tarball da fonte do llama.cpp embutido na midia (vazio = sem fonte).
## O arquivo e copiado para o alvo e o 1o boot usa `--source` com ele: assim o
## passo mais demorado do 1o boot (compilar o llama.cpp) roda SEM rede, e o que
## sera compilado fica pinado no que veio na midia.
ISO_SOURCE_NAME='@@LLAMA_SRC_NAME@@'
SOURCE_DST="/opt/llama-src.tar.gz"

## Senha do ROOT (hash crypt) — vazia = root continua BLOQUEADO (padrão).
## O autoinstall/Subiquity não tem campo de root, então o caminho é aqui:
## `chpasswd -e` espera um hash crypt (nunca texto puro) e o aplica dentro do
## alvo via `curtin in-target`.
## Aspas SIMPLES (ver a nota acima): o `$` do hash tem de chegar ao chpasswd.
ROOT_PASSWORD_HASH='@@ROOT_PASSWORD_HASH@@'

## ---------------------------------------------------------------------------
## Executar um comando DENTRO do sistema instalado.
## O Subiquity (AI_CURTIN=1) usa `curtin in-target --` como chroot.
## ---------------------------------------------------------------------------
in_target() {
    curtin in-target -- "$@"
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

## A identidade vai junto (ADR-002): o `verify-iso.sh` confere a coerência
## identidade x papel e quem administra o alvo consegue ver DE ONDE ela veio
## (`papel` = derivada da função; `explicito` = --username venceu; `padrao-auto`
## = --role auto, sem derivação). Prefixo ISO_ para não colidir com variáveis
## que o shell já define (HOSTNAME é uma delas).
printf 'ROLE=%s\nFAMILY=%s\nFIRSTBOOT_REBOOT=%s\nDISTRO=%s\nISO_BUILD=%s\nMODEL_FILE=%s\nLLAMA_SRC=%s\nISO_USERNAME=%s\nISO_HOSTNAME=%s\nIDENTITY_SOURCE=%s\n' \
    '@@ROLE@@' '@@FAMILY@@' '@@FIRSTBOOT_REBOOT@@' '@@DISTRO@@' '@@ISO_BUILD@@' "${MODEL_FILE}" "${LLAMA_SRC}" \
    '@@USERNAME@@' '@@HOSTNAME@@' '@@IDENTITY_SOURCE@@' \
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
APT_REPO_LIST="/target/etc/apt/sources.list.d/ai-cpu-os-local.list"

## REGRA DE OURO DESTE BLOCO: é MELHOR um alvo sem repositório local do que um
## alvo com o apt QUEBRADO. Um `.list` apontando para um repositório
## incompleto (sem `Release`/`Packages`, ou de outra release) faz TODO
## `apt-get update` falhar com "does not have a Release file" — e, como o apt
## aborta no erro, NADA mais instala: nem `openssh-server`, nem `git`, nada.
## Medido numa instalação real (sessão #36): o usuário ficou com a máquina sem
## SSH e sem conseguir instalar o SSH, porque o apt estava travado nesse erro.
## Por isso aqui o repositório é VALIDADO e TESTADO antes de virar fonte.
if [ -d "${APT_REPO_SRC}" ]; then
    log "carregando o repositório apt local para ${APT_REPO_DST}"
    mkdir -p "/target${APT_REPO_DST}"
    if ! cp -a "${APT_REPO_SRC}/." "/target${APT_REPO_DST}/"; then
        log "AVISO: falha ao copiar o repositório apt local; resta a rede"
    else
        ## (1) O repositório está completo? `Release` + índice de pacotes.
        # shellcheck disable=SC2086
        if [ ! -f "/target${APT_REPO_DST}/Release" ] || \
           ! ls "/target${APT_REPO_DST}"/Packages* >/dev/null 2>&1; then
            log "AVISO: repositório local INCOMPLETO (sem Release ou Packages); NÃO será usado"
            rm -f "${APT_REPO_LIST}"
        else
            ## (2) O repositório é da MESMA release do alvo? Um repo de outra
            ## release é aceito pelo apt e depois gera conflito de dependências
            ## (pior que não ter repo).
            _repo_ok=1
            if [ -f /target/etc/os-release ]; then
                ## `sed` em vez de `.` (source): o shellcheck não segue o arquivo
                ## (SC1091) e não precisamos de mais nada além do codename.
                _cn="$(sed -n 's/^VERSION_CODENAME=\(.*\)$/\1/p' /target/etc/os-release 2>/dev/null | tr -d '"' | head -1)"
                # `Release` gerado por versões ANTIGAS do build-iso.sh trazia
                ## `Codename: ./` (sem release nenhuma). Não dá para afirmar que
                # é de outra release — e o teste REAL do apt logo abaixo decide.
                # Só reprovamos quando o Release DIZ uma release diferente.
                _rel_cn="$(sed -n 's/^Codename:[[:space:]]*//p' "/target${APT_REPO_DST}/Release" 2>/dev/null | head -1)"
                case "${_rel_cn}" in
                    ""|"./"|"*") : ;;   # desconhecida -> o apt decide
                    *)
                        if [ -n "${_cn}" ] && [ "${_rel_cn}" != "${_cn}" ]; then
                            _repo_ok=0
                            log "AVISO: repositório local é de OUTRA release (${_rel_cn} != ${_cn}); NÃO será usado"
                        fi
                        ;;
                esac
            fi
            if [ "${_repo_ok}" -eq 1 ]; then
                mkdir -p /target/etc/apt/sources.list.d
                printf 'deb [trusted=yes] file://%s ./\n' "${APT_REPO_DST}" > "${APT_REPO_LIST}"
                ## (3) Teste REAL: o próprio apt, restrito a este sources. É a
                ## única prova que vale — arquivo presente não garante repo
                ## legível (assinatura, índice corrompido, permissão).
                if in_target apt-get update \
                        -o Dir::Etc::sourcelist="sources.list.d/$(basename "${APT_REPO_LIST}")" \
                        -o Dir::Etc::sourceparts="-" \
                        -o APT::Get::List-Cleanup="0" >/dev/null 2>&1; then
                    printf 'APT_REPO=%s\n' "${APT_REPO_DST}" >> "${DST}/.iso-config"
                    log "repositório local em ${APT_REPO_DST} (validado pelo apt e gravado no alvo)"
                else
                    rm -f "${APT_REPO_LIST}"
                    log "AVISO: o apt do alvo REJEITOU o repositório local; fonte removida (resta a rede)"
                fi
            fi
        fi
    fi
else
    log "sem repositório apt local nesta ISO (--iso-repo none)"
fi

## ---------------------------------------------------------------------------
## 2-e. Rede do sistema instalado
## ---------------------------------------------------------------------------
## Por que isto existe: o autoinstall do Subiquity NÃO grava uma configuração
## de rede persistente no alvo quando a chave `network:` está ausente. O
## sistema instalava e subia com a placa DOWN (sem DHCP) até alguém rodar
## `ip link set ... up`/`dhclient` à mão — foi o que aconteceu numa instalação
## real. A ISO agora traz o netplan PRONTO em /ai-cpu-os-boot/ai-cpu-os-netplan.yaml
## (gerado pelo build-iso.sh a partir de --network) e nós o copiamos para o
## alvo. É o MESMO YAML que o instalador usou: uma fonte de verdade só.
NETWORK_MODE='@@NETWORK_MODE@@'
NET_IP='@@NET_IP@@'
NET_GATEWAY='@@NET_GATEWAY@@'
NET_DNS='@@NET_DNS@@'

if [ "${NETWORK_MODE}" = "none" ]; then
    log "rede: --network none (nenhuma configuracao gravada; a placa pode subir DOWN)"
else
    NETPLAN_SRC="${SRC}/ai-cpu-os-boot/ai-cpu-os-netplan.yaml"
    NETPLAN_DST="/target/etc/netplan/99-ai-cpu-os.yaml"
    if [ -f "${NETPLAN_SRC}" ]; then
        mkdir -p /target/etc/netplan
        # O instalador (e o cloud-init) podem ter deixado OUTRA definicao para
        # a mesma placa. Duas definicoes do mesmo adaptador fazem o netplan
        # recusar a configuracao; a nossa e a fonte de verdade.
        for f in /target/etc/netplan/00-installer-config.yaml \
                 /target/etc/netplan/50-cloud-init.yaml \
                 /target/etc/netplan/01-netcfg.yaml; do
            if [ -f "$f" ]; then
                mv "$f" "$f.ai-cpu-os.bak" 2>/dev/null && \
                    log "netplan: ${f} movido para .ai-cpu-os.bak"
            fi
        done
        if cp "${NETPLAN_SRC}" "${NETPLAN_DST}"; then
            # 0600: e o que o netplan espera (ele avisa quando o arquivo e
            # legivel por outros usuarios).
            chmod 0600 "${NETPLAN_DST}"
            log "rede: ${NETPLAN_DST} gravado (modo ${NETWORK_MODE})"
            if [ "${NETWORK_MODE}" = "static" ]; then
                log "rede: IP ${NET_IP} via ${NET_GATEWAY} (DNS: ${NET_DNS})"
            fi
        else
            log "AVISO: falha ao gravar ${NETPLAN_DST}; o alvo pode subir sem rede"
        fi
        # cloud-init desligado para nao reescrever o netplan a cada boot.
        mkdir -p /target/etc/cloud/cloud.cfg.d
        cat > /target/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg <<'CFG'
network: {config: disabled}
CFG
    else
        log "AVISO: ${NETPLAN_SRC} ausente na midia; o alvo pode subir sem rede"
    fi
fi

## ---------------------------------------------------------------------------
## 3. Serviço de primeiro boot
## ---------------------------------------------------------------------------
log "instalando o serviço de primeiro boot"
cp "${SRC}/ai-cpu-os-boot/firstboot.sh" "${DST}/iso/firstboot.sh"
cp "${SRC}/ai-cpu-os-boot/ai-cpu-os-firstboot.service" "/target${UNIT}"

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
## 4-c. Limpar as fontes de apt do alvo que apontam para a MÍDIA
## ---------------------------------------------------------------------------
## São dois casos distintos, e os dois quebram `apt-get update` no alvo:
##
##  (a) `cdrom:[…]` — gravada pelo próprio instalador e NÃO tem nada a ver
##      com --iso-repo. Depois da
##      instalação a mídia não existe mais, e todo `apt-get update` falha com
##      "o repositório cdrom://… não tem um arquivo Release". Era isso que
##      derrubava o PRIMEIRO BOOT no papel `inference` (rc=100 antes de instalar
##      qualquer dependência) — medido numa VM de verdade, sessão #35.
##  (b) `file:///cdrom/…` (o repositório local de --iso-repo), tratado abaixo.
##
## O espelho oficial (`archive.ubuntu.com`) NUNCA é tocado: é
## o `primary` e é o que faz o sistema continuar atualizável.
log "removendo fontes de apt do tipo 'cdrom:' do alvo (a mídia não existe mais)"
for _f in /target/etc/apt/sources.list /target/etc/apt/sources.list.d/*.list; do
    [ -f "${_f}" ] || continue
    if grep -qE '^[[:space:]]*deb(-src)?[[:space:]]+cdrom:' "${_f}" 2>/dev/null; then
        cp -a "${_f}" "${_f}.bak" 2>/dev/null || true
        grep -vE '^[[:space:]]*deb(-src)?[[:space:]]+cdrom:' "${_f}.bak" > "${_f}" 2>/dev/null || true
        log "removido 'cdrom:' de ${_f}"
    fi
done
for _f in /target/etc/apt/sources.list.d/*.sources; do
    [ -f "${_f}" ] || continue
    if grep -qE '^[[:space:]]*URIs:[[:space:]].*cdrom:' "${_f}" 2>/dev/null; then
        rm -f "${_f}"
        log "removido ${_f} (URI cdrom:)"
    fi
done

## Reexecuta o update UMA vez, já sem as fontes da mídia. Falhar aqui não
## invalida a instalação: o primeiro boot roda `apt-get update` de novo.
if in_target apt-get update >/dev/null 2>&1; then
    log "apt update do alvo OK após a limpeza"
else
    log "AVISO: apt update no alvo falhou (sem rede agora é esperado); rode depois"
fi

APT_REPO_PATH='@@APT_REPO_PATH@@'
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
fi

## ---------------------------------------------------------------------------
## 4-c2. Servidor SSH: GARANTIR que ele exista no alvo
## ---------------------------------------------------------------------------
## POR QUE (medido numa instalação real, sessão #36): a ISO pede
## `ssh: install-server: true` e `openssh-server` em `packages`, mas **isso
## falha em silêncio quando não há rede durante a instalação**. O resultado é o pior tipo de máquina: ela instala,
## sobe, pega IP (ou não) e **não tem NENHUM serviço escutando** — nem SSH. Sem
## tela e sem teclado, não há como entrar nela para consertar. Verificado com
## uma varredura de portas na máquina instalada: 65535 portas em RST, nenhum
## listener.
##
## Por isso o SSH deixa de ser "esperança" e passa a ser verificado AQUI, no
## fim da instalação, quando ainda dá para consertar (a mídia ainda está
## montada e, se houver rede, o espelho oficial responde). Se mesmo assim
## falhar, o alvo recebe um aviso no `/etc/motd` e no `/root/LEIA-SSH.md` —
## quem chegar no console descobre o que fazer em 5 segundos.
## ANTES do SSH: o `sudo`. Sem repositório local, a instalação de pacotes pode
## não ter acontecido, então `sudo` pode faltar no alvo. Sem ele e com o root
## bloqueado, o usuário do grupo `sudo` não administra NADA. Mesmo tratamento
## do SSH: tentar de
## verdade e, se não der, avisar de forma impossível de não ver.
if ! in_target sh -c 'command -v sudo >/dev/null 2>&1 || [ -x /target/usr/bin/sudo ]' 2>/dev/null \
   && [ ! -x /target/usr/bin/sudo ]; then
    log "AVISO: o alvo NÃO tem 'sudo'; tentando instalar agora"
    if in_target apt-get install -y sudo >/dev/null 2>&1; then
        log "sudo instalado no alvo"
    else
        log "ERRO: não foi possível instalar o sudo (sem rede e sem repositório local?)"
        {
            echo ''
            echo ' ATENÇÃO: esta máquina foi instalada SEM o pacote sudo.'
            echo ' Sem ele (e com o root bloqueado) não há acesso administrativo.'
            echo ' No console, como root:  apt-get install -y sudo'
        } >> /target/etc/motd 2>/dev/null || true
    fi
fi

_ssh_ok=0
## `[ -x /target/usr/sbin/sshd ]` é o teste que NÃO depende de chroot: o
## `curtin in-target` pode não estar no PATH em alguns pontos da instalação, e
## um teste que falha por falta do utilitário daria falso negativo (e
## instalaríamos o pacote de novo, sem mal).
if in_target true >/dev/null 2>&1 && in_target sh -c 'command -v sshd >/dev/null 2>&1'; then
    _ssh_ok=1
elif [ -x /target/usr/sbin/sshd ]; then
    _ssh_ok=1
    log "servidor SSH já presente no alvo"
else
    log "AVISO: o alvo NÃO tem servidor SSH; tentando instalar agora"
    if in_target apt-get install -y openssh-server >/dev/null 2>&1; then
        _ssh_ok=1
        log "openssh-server instalado no alvo (tarde, mas antes do 1º boot)"
    else
        log "ERRO: não foi possível instalar o openssh-server (sem rede e sem repositório local?)"
    fi
fi

if [ "${_ssh_ok}" -eq 1 ]; then
    # Habilita no boot: sem isto, o serviço pode existir e não subir.
    in_target systemctl enable ssh >/dev/null 2>&1 \
        || in_target systemctl enable sshd >/dev/null 2>&1 \
        || log "AVISO: não consegui habilitar o ssh no boot (verifique com systemctl)"
    log "SSH habilitado no alvo (login remoto disponível após o boot)"
else
    # Aviso impossível de não ver para quem chegar no console.
    {
        echo ''
        echo '=============================================================='
        echo ' ATENÇÃO: esta máquina foi instalada SEM servidor SSH.'
        echo ' Para liberar o acesso remoto, rode como root:'
        echo '     apt-get update && apt-get install -y openssh-server'
        echo '     systemctl enable --now ssh'
        echo '=============================================================='
    } >> /target/etc/motd 2>/dev/null || true
    {
        echo '# Esta máquina foi instalada SEM servidor SSH'
        echo ''
        echo 'A instalação não conseguiu instalar o pacote openssh-server'
        echo '(provavelmente não havia rede nem repositório local na mídia).'
        echo ''
        echo 'Para habilitar o acesso remoto:'
        echo '    apt-get update && apt-get install -y openssh-server'
        echo '    systemctl enable --now ssh'
        echo '    ip -4 addr show          # descubra o IP'
    } > /target/root/LEIA-SSH.md 2>/dev/null || true
    printf '[ai-cpu-os/iso-late] AVISO: alvo SEM SSH (veja /root/LEIA-SSH.md no alvo)\n' \
        > /dev/console 2>/dev/null || true
fi

## ---------------------------------------------------------------------------
## 4-d. Console serial (opcional) — torna o primeiro boot observável sem tela.
## ---------------------------------------------------------------------------
## Sem isto, um teste headless (iso/test-vm.sh) não vê nada do sistema
## instalado: a saída vai para a tela virtual, que ninguém está olhando.
SERIAL_CONSOLE='@@SERIAL_CONSOLE@@'
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
Rede configurada: @@NETWORK_MODE@@${NET_IP:+ (${NET_IP}${NET_GATEWAY:+ via ${NET_GATEWAY}})}
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
## `chpasswd -e` aplica a senha DENTRO do alvo — o autoinstall não tem campo
## de root, então este é o único caminho.
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

