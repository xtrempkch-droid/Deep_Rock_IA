#!/usr/bin/env bash
#
# iso/build-iso.sh — gera uma ISO de instalação do ai-cpu-os
# -----------------------------------------------------------------------------
# Pega uma ISO oficial, injeta o projeto ai-cpu-os + a configuração de
# instalação automática e remonta uma ISO nova que instala tudo sozinha.
#
# Caminho suportado (`--distro`):
#   * ubuntu (PADRÃO, ÚNICO) → Ubuntu Server live + **autoinstall** (Subiquity).
#     A config vai como `autoinstall.yaml` na RAIZ da ISO (ao lado de `casper/`)
#     e a remontagem usa `xorriso -indev/-outdev -map`, preservando os setores
#     de boot originais byte a byte.
#   * debian → REMOVIDO (ADR-001). `--distro debian` falha com exit 2 e uma
#     mensagem que aponta o ADR. O runtime Debian (build.sh/mods) continua
#     suportado; o que deixou de existir foi a ISO com base Debian.
#
# A ISO gerada:
#   * instala o SO mínimo, não interativo;
#   * copia o projeto para /opt/ai-cpu-os no sistema instalado;
#   * agenda a aplicação do ai-cpu-os para o PRIMEIRO BOOT (no hardware real),
#     via `ai-cpu-os-firstboot.service` — é lá que o papel e a família são
#     detectados do hardware de verdade.
#
# Uso:
#   sudo bash iso/build-iso.sh --disk /dev/nvme0n1 [opções]
#
# Opções:
#   --distro NAME         ubuntu (única base suportada; 'debian' falha — ADR-001)
#   --disk DEV            Disco alvo do particionamento (APAGADO). Obrigatório
#                         sem --dry-run, a menos que --allow-any-disk seja usado.
#                         `--disk auto` = não fixa o disco (o instalador escolhe
#                         o maior) — é o valor certo quando a ISO é para OUTRO PC.
#   --allow-any-disk      Não fixa o disco: o instalador escolhe sozinho.
#   --out PATH            Caminho da ISO de saída (padrão: iso/out/ai-cpu-os-<distro>-<data>.iso)
#   --iso PATH            Usa uma ISO local em vez de baixar.
#   --iso-url URL         URL da ISO (padrão: descobre a versão atual do distro).
#   --sha256 SUM          Checksum esperado (opcional, se --iso for usado).
#   --role NAME           Papel gravado na ISO: auto|inference|builder (padrão: auto).
#   --family NAME         Família gravada na ISO: auto ou um id (padrão: auto).
#   --firstboot-reboot    Reinicia automaticamente ao fim do primeiro boot.
#   --serial-console      Habilita console serial (ttyS0,115200) na ISO **e** no
#                         sistema instalado. É o que torna a instalação e o
#                         primeiro boot observáveis sem tela (usado pelo
#                         iso/test-vm.sh).
#   --no-verify           Não roda o iso/verify-iso.sh no fim (ele é rápido e
#                         somente leitura; o padrão é verificar).
#   --hostname NAME       Hostname do sistema instalado (padrão: <usuario>).
#   --username NAME       Usuário administrativo (padrão: ai-cpu-os; a próxima
#                         fase deriva de --role: ai-inference/ai-builder — ADR-002).
#   --password-hash HASH  Hash da senha (crypt). Se omitido, gera e mostra um.
#   --locale / --keymap / --timezone
#   --extra-packages "…"  Pacotes extras (separados por espaço).
#   --work-dir DIR        Diretório de trabalho (padrão: iso/work).
#   --keep-work           Não apaga o diretório de trabalho no fim.
#   --dry-run             Mostra tudo o que seria feito, sem alterar nada.
#   --yes                 Não pede confirmação (automação/CI).
#   -h | --help           Esta ajuda.
#
# Requisitos: xorriso, curl, sha256sum, tar.
#
# ⚠️ A ISO gerada APAGA o disco alvo. Boote em VM antes de usar em hardware.
# -----------------------------------------------------------------------------

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="${DIR}/${SOURCE}"
done
ISO_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
readonly ISO_DIR
REPO_ROOT="$(cd "${ISO_DIR}/.." && pwd)"
readonly REPO_ROOT

# Ubuntu Server live (amd64). O padrão aponta para a série LTS mais recente;
# para outra versão use --iso-url com a URL do diretório de sua escolha.
readonly UBUNTU_CD_BASE_DEFAULT="https://releases.ubuntu.com/24.04"
# Padrões ANCORADOS de propósito. Sem a âncora, `netinst[.]iso$` também casa
# `debian-edu-*` e `debian-mac-*`, e um `live-server-amd64` frouxo não
# distingue a live-server das variantes desktop/wsl do MESMO SHA256SUMS.
# `[.]` em vez de `\.`: o padrão é passado ao awk via `-v`, e dentro de uma
# string do awk o `\.` vira escape desconhecido (o gawk avisa e o trata como
# `.`, que casa qualquer caractere). A classe evita a ambiguidade.
readonly UBUNTU_ISO_PATTERN='^ubuntu-[0-9][^ ]*-live-server-amd64[.]iso$'

# Modelo embutido na mídia (decisão da sessão #14: a ISO é air-gapped, então o
# .gguf tem de estar NA MÍDIA — não pode ser baixado no 1º boot).
# O nome precisa bater com o DEFAULT_MODEL_NAME do papel inference para o
# MODEL_PATH do serviço sair previsível.
readonly SUGGESTED_MODEL_NAME="Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf"
readonly SUGGESTED_MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"

# Fonte do llama.cpp embutida na midia (--iso-source).
# POR QUE a FONTE tambem vai na midia: o llama.cpp e compilado no 1o boot (decisao
# firmada -- garante o -march da familia REALMENTE detectada). Mas se o 1o boot
# tivesse de clonar do GitHub, a ISO voltaria a exigir rede justamente no passo
# mais demorado. Com o tarball na midia, o passo mais caro do 1o boot funciona
# offline e o que sera compilado fica PINADO e auditavel.
readonly ISO_SOURCE_FILENAME="llama-src.tar.gz"
readonly SUGGESTED_SOURCE_URL="https://github.com/ggml-org/llama.cpp/archive/refs/heads/master.tar.gz"

# Repositório apt local embutido na mídia (--iso-repo).
# POR QUE: a ISO é air-gapped (docs/ISO.md § 3.1). O alvo não pode precisar de
# rede NEM PARA INSTALAR PACOTE — senão o primeiro boot pediria internet para
# compilar o llama.cpp, e a promessa cairia.
#
# Forma: repositório "flat" (índice na raiz) adicionado como fonte EXTRA, via a
# seção `sources` do curtin aceita pelo Subiquity. O espelho oficial continua
# sendo o `primary`, então:
#   * o sistema instalado fica com a configuração normal de arquivo (nada de
#     `file:///cdrom` morto no sources.list);
#   * se o repositório local estiver incompleto, o install AINDA funciona quando
#     houver rede — degrada, não quebra;
#   * sem rede, os pacotes vêm da mídia.
# Qualquer linha de fonte apontando para /cdrom é removida do alvo no
# late-command (ela morreria no primeiro boot, quando a mídia sai).
readonly ISO_REPO_DIRNAME="apt-repo"
# Onde a mídia é montada durante a instalação. É o MESMO caminho que o
# late-command usa para ler /cdrom/ai-cpu-os — ou seja, vale nos dois
# instalador (Subiquity).
readonly APT_REPO_MOUNT="/cdrom"
# Pacotes que o PRIMEIRO BOOT precisa ter JÁ INSTALADOS (é isto que evita que o
# llama-build.sh/install.sh baixem qualquer coisa). É a união de:
#   * `llama-build.sh check_deps`      → build-essential cmake pkg-config
#   * `roles/inference/install.sh`     → ccache libopenblas-dev libgomp1
#                                        python3 python3-venv curl
#                                        ca-certificates pciutils util-linux
#   * `roles/builder` + EXTRA_PACKAGES → git gnupg jq openssh-server sudo
readonly DEFAULT_REPO_PACKAGES="build-essential cmake ccache pkg-config libopenblas-dev libgomp1 python3 python3-venv curl ca-certificates gnupg jq pciutils util-linux openssh-server git sudo"
# Orçamento da mídia: 8 GB acordados. Só avisa — o usuário decide.
readonly ISO_REPO_BUDGET_MB=6000

# --- configuração (sobrescrita por argumentos) ------------------------------
DISTRO="ubuntu"
DISK=""
ALLOW_ANY_DISK=0
# 1 = o --disk informado não existe nesta máquina (deixa rastro no resumo final).
DISK_MISSING_ON_BUILD=0
OUT_ISO=""
INPUT_ISO=""
ISO_URL=""
EXPECTED_SHA=""
ROLE="auto"
FAMILY="auto"
FIRSTBOOT_REBOOT="no"
SERIAL_CONSOLE="no"
NO_VERIFY=0
USERNAME="ai-cpu-os"
USER_FULLNAME="ai-cpu-os"
# Nome HOSTNAME NÃO é usado de propósito: o bash já define uma variável com esse
# nome e sobrescrevê-la confunde quem lê o script.
SYS_HOSTNAME=""
PASSWORD_HASH=""
ROOT_PASSWORD_HASH=""
GENERATED_PASSWORD=""

# --- rede do sistema instalado (--network) ----------------------------------
# Sem esta pré-configuração o Subiquity NÃO grava uma configuração de rede
# persistente no alvo quando o autoinstall não tem a chave `network:` — o
# sistema instala, mas sobe SEM DHCP (a placa fica DOWN até alguém rodar
# `ip link set`/`dhclient` na mão). Foi exatamente o que aconteceu numa
# instalação real (sessão #28). Agora a intenção vai escrita na ISO:
#
#   auto   (padrão) → DHCP em todas as interfaces Ethernet (en*/eth*)
#   dhcp            → igual a auto, mas explícito
#   static          → IP fixo (exige --network-ip e --network-gateway)
#   none            → não grava configuração de rede (comportamento antigo)
NETWORK_MODE="auto"
NET_IFACE=""          # vazio = casa en*/eth* por glob (netplan) / auto (d-i)
NET_IP=""             # aceita 192.168.1.50 ou 192.168.1.50/24
NET_GATEWAY=""
NET_DNS=""            # vazio = 1.1.1.1,8.8.8.8 (só no modo static)
NET_PREFIX="24"       # usado quando --network-ip vem sem /prefixo
# Derivados de validate_network (usados no late-command).
NET_IP_ADDR=""
NET_PREFIX_EFF=""
NET_NETMASK=""
NET_DNS_SPACE=""

LOCALE="pt_BR.UTF-8"
LANG_CODE="pt"
COUNTRY="BR"
KEYMAP="br"
TIMEZONE="America/Sao_Paulo"
GRUB_WITH_OTHER_OS="true"
EXTRA_PACKAGES="sudo git curl ca-certificates build-essential pkg-config libopenblas-dev gnupg jq pciutils util-linux openssh-server"
WORK_DIR="${ISO_DIR}/work"
KEEP_WORK=0
DRY_RUN=0
ASSUME_YES=0
CHECK_TEMPLATES=0
# 1 = o autoteste de templates NÃO apaga a árvore e imprime TEMPLATES_DIR=…
# (o teste de disco inspeciona o YAML gerado; também ajuda a depurar).
KEEP_TEMPLATES=0

# --- modelo na mídia (--iso-model) ------------------------------------------
# auto  → baixa o modelo sugerido NA MÁQUINA QUE GERA A ISO (aqui a rede é
#         aceitável; o que não pode haver é rede no 1º boot do alvo).
# none  → ISO sem modelo (o usuário traz o .gguf por pendrive/--model-file).
# CAMINHO → um .gguf seu.
ISO_MODEL="auto"
MODEL_SRC=""      # caminho local do .gguf a embutir (vazio = sem modelo)
MODEL_NAME=""     # nome do arquivo dentro da ISO (vazio = sem modelo)

# --- repositório apt local (--iso-repo) --------------------------------------
# auto  → baixa os .deb necessários NA MÁQUINA QUE GERA A ISO e embute.
# none  → ISO sem repositório (o alvo precisará de rede para instalar pacotes).
# DIR   → usa um diretório com .deb já baixados.
ISO_SOURCE="auto"
SOURCE_FILE=""    # caminho local do tarball a embutir (vazio = sem fonte)
SOURCE_NAME=""    # nome do arquivo dentro da ISO (vazio = sem fonte)
ISO_REPO="auto"
ISO_REPO_PACKAGES=""        # vazio = DEFAULT_REPO_PACKAGES
ISO_REPO_ALLOW_MISMATCH=0   # permite repo de outra release (sabe o que faz)
REPO_DIR_LOCAL=""           # árvore pronta do repo a embutir (vazio = sem repo)
APT_REPO_PATH=""            # caminho dentro da ISO, ex.: /cdrom/apt-repo
APT_REPO_PATH_REL=""        # o mesmo, relativo à raiz da ISO (ex.: apt-repo)
# Espelho oficial: é o `primary` do autoinstall e é o que fica configurado no
# sistema INSTALADO (o repositório local serve à instalação, não ao dia a dia).
APT_PRIMARY_URI="http://archive.ubuntu.com/ubuntu"
REPO_PKG_COUNT=0
REPO_SIZE_MB=0

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

run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then log_info "[dry-run] ${desc}: $*"; return 0; fi
  log_info "${desc}: $*"
  "$@"
}

# ---------------------------------------------------------------------------
# Trava de instância única
# ---------------------------------------------------------------------------
# POR QUE EXISTE: dois builds ao mesmo tempo compartilhando o mesmo --work-dir
# brigam pelos arquivos `.part` (o modelo de ~1,1 GB e a fonte do llama.cpp).
# Um build renomeia o `.part` para o nome final enquanto o outro ainda escreve
# nele pelo fd aberto — e o segundo morre com um erro que não explica nada:
#
#   mv: cannot stat '…/iso/work/models/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf.part':
#   No such file or directory
#
# O arquivo NUNCA esteve ausente do disco: ele foi RENOMEADO pelo outro build.
# O sintoma (a máquina "travando") também casa: dois downloads de 1,1 GB e dois
# builds pesados na mesma máquina modesta. Um build por vez é a regra.
#
# A UI é o gatilho mais provável (dois cliques em "Gerar"); ela também recusa
# o segundo build (segunda camada, ver webui/server.py).
acquire_build_lock() {
  if [[ $DRY_RUN -eq 1 ]]; then
    # No dry-run nada é escrito, então não há o que proteger — e o CI roda
    # dry-runs com frequência (não queremos criar trava em árvore de teste).
    return 0
  fi
  local lockfile="${ISO_DIR}/.build-iso.lock"
  if ! command -v flock >/dev/null 2>&1; then
    # Degrada com aviso (Regra 13-a): sem flock, seguimos — mas dizemos o risco.
    log_warn "flock não encontrado: não vou travar instância única."
    log_warn "NÃO rode dois builds ao mesmo tempo no mesmo --work-dir."
    return 0
  fi
  if ! exec 9>"$lockfile"; then
    # Não abortamos: não poder escrever no próprio diretório é ambiente, não
    # entrada do usuário (Regra 13-a). O risco é o mesmo de não ter o flock.
    log_warn "Não consegui abrir ${lockfile} para travar: seguindo SEM trava."
    return 0
  fi
  if ! flock -n 9; then
    local dono; dono="$(cat "$lockfile" 2>/dev/null || true)"
    log_error "Já existe um build da ISO em andamento (trava: ${lockfile})."
    [[ -n "$dono" ]] && log_error "PID do build que está rodando: ${dono}"
    log_error "Dois builds no mesmo ${WORK_DIR} corrompem o modelo/fonte (.part)"
    log_error "e o sintoma é um 'mv: cannot stat … .part' sem explicação."
    log_error "Espere o outro terminar (ou mate-o) e rode de novo."
    exit 1
  fi
  printf '%s\n' "$$" >&9 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Download com verificação de verdade
# ---------------------------------------------------------------------------
# POR QUE NÃO CONFIAR SÓ NO EXIT DO CURL: já vimos o `.part` não existir depois
# de um `curl` que retornou 0 (build concorrente, disco cheio, download
# abortado). O `mv` seguinte então falhava com "No such file or directory", um
# erro que aponta para o lugar errado.
#
# As opções de tempo existem para o OUTRO sintoma relatado: download que
# "trava" para sempre. `--speed-time/--speed-limit` abortam quando a conexão
# fica estagnada (não quando ela é apenas LENTA); `--connect-timeout` cobre o
# caso de não haver resposta nenhuma.
#
# Uso: download_to <url> <destino-final> <descrição>
download_to() {
  local url="$1" dest="$2" desc="$3"
  log_info "Baixando ${desc}: ${url}"
  if ! curl -fL --retry 3 --create-dirs \
            --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
            -o "${dest}.part" "$url"; then
    rm -f "${dest}.part"
    return 1
  fi
  if [[ ! -s "${dest}.part" ]]; then
    log_warn "O download de ${desc} terminou 'com sucesso' mas ${dest}.part não existe (ou está vazio)."
    log_warn "Causas prováveis: OUTRO build no mesmo --work-dir, disco cheio, ou o processo foi interrompido."
    rm -f "${dest}.part"
    return 1
  fi
  mv -f "${dest}.part" "$dest"
  return 0
}

confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then return 0; fi
  local reply; read -r -p "${prompt} [s/N] " reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

usage() {
  cat <<'EOF'
build-iso.sh — gera uma ISO de instalação do ai-cpu-os

Uso:
  sudo bash iso/build-iso.sh --disk /dev/nvme0n1 [opções]

Opções principais:
  --distro NAME         ubuntu (autoinstall). 'debian' foi REMOVIDO (ADR-001)
                        e falha com exit 2.
  --disk DEV            Disco alvo do particionamento (APAGADO).
  --disk auto           NÃO fixa o disco: o instalador escolhe o maior. Use isto
                        quando a ISO vai instalar em OUTRA máquina (um disco
                        fixado que não existe no alvo impede a automação).
  --allow-any-disk      Não fixa o disco (o instalador escolhe).
  --out PATH            ISO de saída (padrão: iso/out/ai-cpu-os-<distro>-<data>.iso).
  --iso PATH            Usa uma ISO local em vez de baixar.
  --iso-url URL         URL da ISO (padrão: descobre a versão atual).
  --sha256 SUM          Checksum esperado (com --iso).
  --role NAME           Papel gravado na ISO: auto|inference|builder (padrão: auto).
  --family NAME         Família gravada na ISO: auto ou um id (padrão: auto).
  --firstboot-reboot    Reinicia ao fim do primeiro boot (aplica C-states).
  --serial-console      Console serial (ttyS0) na ISO e no sistema instalado —
                        é o que permite observar a instalação e o 1º boot sem
                        tela (usado pelo iso/test-vm.sh).
  --no-verify           Não roda o iso/verify-iso.sh no fim.
  --hostname NAME       Hostname do sistema instalado (padrão: <usuario>).
  --username NAME       Usuário administrativo (padrão: ai-cpu-os; em breve
                        derivado do papel: ai-inference/ai-builder — ADR-002).
  --password-hash HASH  Hash crypt da senha do usuário. Se omitido, gera e mostra um.
  --root-password-hash HASH  Hash crypt da senha do ROOT (opcional). Sem ele, o
                        root fica BLOQUEADO (padrão). Com ele, o root é
                        habilitado: no Ubuntu via late-command (chpasswd -e);
                        e o root fica habilitado no alvo.
  --network MODE        Rede do sistema INSTALADO (gravada na ISO):
                          auto (padrão) — DHCP em todas as interfaces Ethernet
                          dhcp          — igual a auto, mas explícito
                          static        — IP fixo (exige --network-ip e
                                          --network-gateway)
                          none          — não grava configuração (a placa pode
                                          subir DOWN; foi o padrão antigo)
                        Sem isto o Subiquity não deixa configuração persistente
                        no alvo e o sistema sobe SEM DHCP.
  --network-interface NOME  Interface alvo (ex.: enp5s0). Vazio = casa en*/eth*
                        por glob. Em modo
                        static, informe-a se a placa não for en*/eth*.
  --network-ip IP[/PREFIXO]  Endereço do modo static (prefixo padrão: 24).
  --network-gateway IP  Gateway do modo static (obrigatório no modo static).
  --network-dns "A,B"   Servidores DNS do modo static (padrão: 1.1.1.1,8.8.8.8).
  --network-prefix N    Prefixo usado quando --network-ip vem sem /N (padrão: 24).
  --locale / --keymap / --timezone
  --extra-packages "…"  Pacotes extras instalados no alvo.
  --iso-model VALOR     Modelo .gguf embutido na mídia (a ISO é air-gapped, logo
                        o modelo não pode ser baixado no 1º boot):
                          auto (padrão) — baixa o Qwen2.5-Coder-1.5B (~1,1 GB)
                          none          — nenhum modelo na ISO
                          CAMINHO       — um arquivo .gguf seu
                        O late-command o copia para /opt/models no alvo.
  --iso-source VALOR    Fonte do llama.cpp embutida na midia (o 1o boot compila
                        SEM rede -- ver docs/ISO.md secao 3.1):
                          auto (padrao) -- baixa o tarball do GitHub (master)
                          none          -- nenhuma fonte na ISO (o 1o boot clona)
                          CAMINHO       -- um .tar.gz seu (precisa ter CMakeLists.txt)
  --iso-repo VALOR      Repositório apt local embutido na mídia (para o alvo
                        instalar pacotes SEM internet):
                          auto (padrão) — baixa os .deb necessários aqui
                          none          — nenhum repositório na ISO
                          DIR           — usa um diretório com .deb baixados
  --iso-repo-packages "…"  Pacotes que o repositório deve cobrir (padrão:
                        toolchain de build + dependências dos papéis).
  --iso-repo-allow-mismatch  Monta o repo mesmo com release diferente da ISO.
                        Sem isto, um repo que não casaria é PULADO com aviso
                        (o build não falha: a ISO sai sem repo e precisa de rede).
                        ⚠️ Use só para teste: .deb de outra release quebram a
                        instalação.
  --work-dir DIR        Diretório de trabalho (padrão: iso/work).
  --keep-work           Não apaga o diretório de trabalho.
  --check-templates     Autoteste: substitui os templates e valida o YAML gerado
  --keep-templates      Não apaga a árvore do autoteste (imprime TEMPLATES_DIR=…)
                        (não gera ISO, não precisa de disco nem root).
  --dry-run             Simula tudo, sem alterar nada.
  --yes                 Não pede confirmação.
  -h | --help           Esta ajuda.

Requisitos: xorriso, curl, sha256sum, tar.

⚠️ A ISO gerada APAGA o disco alvo. Boote em VM antes de usar em hardware.
   Ver docs/ISO.md e o Bloco M de docs/VALIDATION.md.
EOF
}

# ---------------------------------------------------------------------------
# Rede: validação e normalização (ver --network)
# ---------------------------------------------------------------------------
NET_DNS_DEFAULT="1.1.1.1,8.8.8.8"

# IPv4 estrito (cada octeto 0-255, sem zeros à esquerda). É o que vai para o
# netplan — um valor torto aqui deixaria o alvo sem rede.
RE_IPV4='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'
RE_IFACE='^[A-Za-z0-9_.:-]+$'

# Prefixo CIDR → máscara decimal.
prefix_to_netmask() {
  local p="$1" octet out="" i
  for i in 0 1 2 3; do
    if (( p >= 8 * (i + 1) )); then
      octet=255
    elif (( p > 8 * i )); then
      octet=$(( 256 - (1 << (8 - (p - 8 * i))) ))
    else
      octet=0
    fi
    out="${out:+${out}.}${octet}"
  done
  printf '%s' "$out"
}

validate_network() {
  case "$NETWORK_MODE" in
    auto|dhcp|static|none) ;;
    *) log_error "Rede inválida: '${NETWORK_MODE}' (use auto, dhcp, static ou none)."; exit 2 ;;
  esac

  if [[ -n "$NET_IFACE" ]]; then
    if ! [[ "$NET_IFACE" =~ $RE_IFACE ]]; then
      log_error "Interface inválida: '${NET_IFACE}' (esperado algo como enp5s0)."
      exit 2
    fi
  fi

  if [[ "$NETWORK_MODE" != "static" ]]; then
    # Um default NUNCA pode derrubar o build (Regra 13-a): se o usuário passou
    # endereço sem escolher static, avisamos e seguimos no modo escolhido.
    if [[ -n "$NET_IP" || -n "$NET_GATEWAY" ]]; then
      log_warn "--network-ip/--network-gateway exigem --network static; ignorados no modo '${NETWORK_MODE}'."
      NET_IP=""; NET_GATEWAY=""; NET_DNS=""
    fi
    NET_IP_ADDR=""; NET_PREFIX_EFF=""; NET_NETMASK=""; NET_DNS_SPACE=""
    if [[ "$NETWORK_MODE" == "none" ]]; then
      log_warn "--network none: o alvo pode subir SEM rede (a placa fica DOWN até configurar à mão)."
    fi
    return 0
  fi

  [[ -n "$NET_IP" ]] || { log_error "--network static exige --network-ip."; exit 2; }
  [[ -n "$NET_GATEWAY" ]] || { log_error "--network static exige --network-gateway."; exit 2; }

  local addr prefix
  if [[ "$NET_IP" == */* ]]; then
    addr="${NET_IP%%/*}"; prefix="${NET_IP##*/}"
  else
    addr="$NET_IP"; prefix="$NET_PREFIX"
  fi
  if ! [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || (( 10#$prefix < 1 || 10#$prefix > 32 )); then
    log_error "Prefixo inválido: '${prefix}' (use 1..32)."
    exit 2
  fi
  if ! [[ "$addr" =~ $RE_IPV4 ]]; then
    log_error "IP inválido: '${addr}'."
    exit 2
  fi
  if ! [[ "$NET_GATEWAY" =~ $RE_IPV4 ]]; then
    log_error "Gateway inválido: '${NET_GATEWAY}'."
    exit 2
  fi
  NET_IP="${addr}/${prefix}"

  [[ -n "$NET_DNS" ]] || NET_DNS="$NET_DNS_DEFAULT"
  # Aceita "1.1.1.1 8.8.8.8", "1.1.1.1,8.8.8.8" e "1.1.1.1, 8.8.8.8".
  NET_DNS="$(printf '%s' "$NET_DNS" | tr -s '[:space:]' ',' | sed -e 's/,,*/,/g' -e 's/^,//' -e 's/,$//')"
  [[ -n "$NET_DNS" ]] || { log_error "--network-dns vazio (informe ao menos um IP)."; exit 2; }
  local d
  local -a dns_list=()
  IFS=',' read -r -a dns_list <<<"$NET_DNS"
  for d in "${dns_list[@]}"; do
    [[ -n "$d" ]] || continue
    if ! [[ "$d" =~ $RE_IPV4 ]]; then
      log_error "DNS inválido: '${d}'."
      exit 2
    fi
  done
  [[ ${#dns_list[@]} -gt 0 ]] || { log_error "--network-dns vazio."; exit 2; }

  NET_IP_ADDR="${NET_IP%%/*}"
  NET_PREFIX_EFF="${NET_IP##*/}"
  NET_NETMASK="$(prefix_to_netmask "$NET_PREFIX_EFF")"
  NET_DNS_SPACE="$(printf '%s' "$NET_DNS" | tr ',' ' ')"

  if [[ -z "$NET_IFACE" ]]; then
    log_warn "--network static sem --network-interface: aplicarei em en* (se houver mais de uma placa Ethernet, o IP se repete)."
  fi
  log_info "Rede do alvo: static ${NET_IP} via ${NET_GATEWAY} (DNS: ${NET_DNS})"
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --distro)          [[ $# -ge 2 ]] || { log_error "--distro exige valor"; exit 2; }; DISTRO="$2"; shift 2 ;;
      --disk)            [[ $# -ge 2 ]] || { log_error "--disk exige valor"; exit 2; }; DISK="$2"; shift 2 ;;
      --allow-any-disk)  ALLOW_ANY_DISK=1; shift ;;
      --out)             [[ $# -ge 2 ]] || { log_error "--out exige valor"; exit 2; }; OUT_ISO="$2"; shift 2 ;;
      --iso)             [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; INPUT_ISO="$2"; shift 2 ;;
      --iso-url)         [[ $# -ge 2 ]] || { log_error "--iso-url exige valor"; exit 2; }; ISO_URL="$2"; shift 2 ;;
      --sha256)          [[ $# -ge 2 ]] || { log_error "--sha256 exige valor"; exit 2; }; EXPECTED_SHA="$2"; shift 2 ;;
      --role)            [[ $# -ge 2 ]] || { log_error "--role exige valor"; exit 2; }; ROLE="$2"; shift 2 ;;
      --family)          [[ $# -ge 2 ]] || { log_error "--family exige valor"; exit 2; }; FAMILY="$2"; shift 2 ;;
      # Compatibilidade com a interface antiga (perfil).
      --profile)
        [[ $# -ge 2 ]] || { log_error "--profile exige valor"; exit 2; }
        log_warn "--profile está obsoleto; use --role (xeon→inference, ryzen→builder)."
        case "$2" in
          xeon)  ROLE="inference" ;;
          ryzen) ROLE="builder" ;;
          auto)  ROLE="auto" ;;
          *)     ROLE="$2" ;;
        esac
        shift 2 ;;
      --firstboot-reboot) FIRSTBOOT_REBOOT="yes"; shift ;;
      --serial-console)   SERIAL_CONSOLE="yes"; shift ;;
      --no-verify)        NO_VERIFY=1; shift ;;
      --hostname)        [[ $# -ge 2 ]] || { log_error "--hostname exige valor"; exit 2; }; SYS_HOSTNAME="$2"; shift 2 ;;
      --username)        [[ $# -ge 2 ]] || { log_error "--username exige valor"; exit 2; }; USERNAME="$2"; shift 2 ;;
      --password-hash)   [[ $# -ge 2 ]] || { log_error "--password-hash exige valor"; exit 2; }; PASSWORD_HASH="$2"; shift 2 ;;
      --root-password-hash) [[ $# -ge 2 ]] || { log_error "--root-password-hash exige valor"; exit 2; }; ROOT_PASSWORD_HASH="$2"; shift 2 ;;
      --network)         [[ $# -ge 2 ]] || { log_error "--network exige valor (auto|dhcp|static|none)"; exit 2; }; NETWORK_MODE="$2"; shift 2 ;;
      --network-interface) [[ $# -ge 2 ]] || { log_error "--network-interface exige valor"; exit 2; }; NET_IFACE="$2"; shift 2 ;;
      --network-ip)      [[ $# -ge 2 ]] || { log_error "--network-ip exige valor"; exit 2; }; NET_IP="$2"; shift 2 ;;
      --network-gateway) [[ $# -ge 2 ]] || { log_error "--network-gateway exige valor"; exit 2; }; NET_GATEWAY="$2"; shift 2 ;;
      --network-dns)     [[ $# -ge 2 ]] || { log_error "--network-dns exige valor"; exit 2; }; NET_DNS="$2"; shift 2 ;;
      --network-prefix)  [[ $# -ge 2 ]] || { log_error "--network-prefix exige valor"; exit 2; }; NET_PREFIX="$2"; shift 2 ;;
      --locale)          [[ $# -ge 2 ]] || { log_error "--locale exige valor"; exit 2; }; LOCALE="$2"; shift 2 ;;
      --keymap)          [[ $# -ge 2 ]] || { log_error "--keymap exige valor"; exit 2; }; KEYMAP="$2"; shift 2 ;;
      --timezone)        [[ $# -ge 2 ]] || { log_error "--timezone exige valor"; exit 2; }; TIMEZONE="$2"; shift 2 ;;
      --extra-packages)  [[ $# -ge 2 ]] || { log_error "--extra-packages exige valor"; exit 2; }; EXTRA_PACKAGES="$2"; shift 2 ;;
      --iso-model)       [[ $# -ge 2 ]] || { log_error "--iso-model exige valor (auto|none|CAMINHO)"; exit 2; }; ISO_MODEL="$2"; shift 2 ;;
      --iso-source)      [[ $# -ge 2 ]] || { log_error "--iso-source exige valor (auto|none|CAMINHO)"; exit 2; }; ISO_SOURCE="$2"; shift 2 ;;
      --iso-repo)        [[ $# -ge 2 ]] || { log_error "--iso-repo exige valor (auto|none|DIR)"; exit 2; }; ISO_REPO="$2"; shift 2 ;;
      --iso-repo-packages) [[ $# -ge 2 ]] || { log_error "--iso-repo-packages exige valor"; exit 2; }; ISO_REPO_PACKAGES="$2"; shift 2 ;;
      --iso-repo-allow-mismatch) ISO_REPO_ALLOW_MISMATCH=1; shift ;;
      --work-dir)        [[ $# -ge 2 ]] || { log_error "--work-dir exige valor"; exit 2; }; WORK_DIR="$2"; shift 2 ;;
      --keep-work)       KEEP_WORK=1; shift ;;
      --check-templates) CHECK_TEMPLATES=1; DRY_RUN=1; shift ;;
      --keep-templates) KEEP_TEMPLATES=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --yes)             ASSUME_YES=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  # ADR-001 (docs/DECISIONS.md): a base ÚNICA da ISO é Ubuntu Server.
  # `--distro debian` falha com mensagem clara — NÃO cai em ramo morto. O
  # runtime Debian (build.sh/mods) continua suportado; o que saiu foi a ISO.
  case "$DISTRO" in
    ubuntu) ;;
    debian)
      log_error "--distro debian foi REMOVIDO: a base única da ISO é Ubuntu Server (ADR-001)."
      log_error "O runtime Debian (build.sh/mods) continua suportado; só a ISO não."
      log_error "Veja docs/DECISIONS.md, ADR-001. Gere com: --distro ubuntu"
      exit 2 ;;
    *)
      log_error "Distro inválida: '${DISTRO}' (a única base suportada é ubuntu)."
      exit 2 ;;
  esac

  case "$ROLE" in
    auto|inference|builder) ;;
    *) log_error "Papel inválido: '${ROLE}' (use auto, inference ou builder)."; exit 2 ;;
  esac

  if [[ -z "$SYS_HOSTNAME" ]]; then
    SYS_HOSTNAME="$(printf '%s' "$USERNAME" | tr '_' '-')"
  fi

  validate_network

  if [[ -z "$DISK" && $ALLOW_ANY_DISK -eq 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Informe o disco alvo com --disk /dev/xxx (será APAGADO)."
    log_error "Se você entende o risco e quer deixar o instalador escolher, use --disk auto (ou --allow-any-disk)."
    exit 2
  fi

  # `--disk auto` NÃO pode virar `match: {path: auto}` no autoinstall: isso é um
  # caminho que não existe, nenhum disco casa e o Subiquity NÃO instala sozinho.
  # Era exatamente o que acontecia — e a documentação recomendava `--disk auto`
  # como a mitigação para "o disco fixado não existe no alvo". A mitigação
  # documentada estava quebrada; aqui ela passa a significar de verdade
  # "não fixe o disco" (equivalente a --allow-any-disk).
  if [[ "$DISK" == "auto" || "$DISK" == "any" || "$DISK" == "none" ]]; then
    log_info "--disk ${DISK}: o disco NÃO será fixado (o instalador escolhe o maior)."
    DISK=""
    ALLOW_ANY_DISK=1
  fi

  # Formato do disco: um caminho de dispositivo de bloco. Pegar um erro de
  # digitação AQUI é barato; descobrir na instalação, não.
  if [[ -n "$DISK" && ! "$DISK" =~ ^/dev/[a-zA-Z0-9]+$ ]]; then
    log_error "--disk ${DISK}: não parece um dispositivo de bloco (ex.: /dev/nvme0n1, /dev/sda)."
    log_error "Use --disk auto para deixar o instalador escolher."
    exit 2
  fi

  # O disco fixado existe NESTA máquina? Se não, é quase certo que ele não
  # existe NO ALVO também — o modo mais provável de a instalação automática
  # falhar em hardware real (o default do CI era /dev/vda, que só existe em VM).
  # É AVISO, não erro: gerar a ISO para OUTRA máquina é legítimo, e o disco do
  # alvo pode simplesmente não estar plugado aqui. Mas quem lê o log precisa
  # saber que a mídia sai com um disco fixado que esta máquina não tem.
  #
  # Vale também em --dry-run de propósito: "simular primeiro" é exatamente a
  # hora de descobrir que o disco digitado não existe.
  if [[ -n "$DISK" && ! -b "$DISK" ]]; then
    log_warn "O disco fixado ${DISK} NÃO existe nesta máquina."
    log_warn "Se ele também não existir no ALVO, o Subiquity não acha disco que case"
    log_warn "e a instalação automática NÃO acontece. Se a ISO é para outro PC, use"
    log_warn "--disk auto (o instalador escolhe o maior disco) ou o --disk do alvo."
    DISK_MISSING_ON_BUILD=1
  fi

  if [[ -z "$OUT_ISO" ]]; then
    OUT_ISO="${ISO_DIR}/out/ai-cpu-os-${DISTRO}-$(date +%Y%m%d).iso"
  fi
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
check_deps() {
  section "Dependências"
  local missing=()
  local c
  for c in xorriso curl sha256sum tar find awk sed; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_warn "Faltam ferramentas (${missing[*]}) — ok em --dry-run, mas necessárias para gerar a ISO."
      log_warn "Instale com: apt-get install -y xorriso curl coreutils tar findutils"
    else
      log_error "Faltam ferramentas obrigatórias: ${missing[*]}"
      log_error "Instale com: apt-get install -y xorriso curl coreutils tar findutils"
      exit 1
    fi
  else
    log_ok "Ferramentas obrigatórias presentes (xorriso $(xorriso --version 2>/dev/null | head -1 | awk '{print $2}'))."
  fi

}

# ---------------------------------------------------------------------------
# Senha (hash) — nunca gravamos senha em texto puro na ISO
# ---------------------------------------------------------------------------
resolve_password() {
  if [[ -n "$PASSWORD_HASH" ]]; then
    log_info "Usando o hash de senha fornecido via --password-hash."
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] geraria uma senha aleatória e o hash crypt correspondente."
    PASSWORD_HASH='$6$EXEMPLO$dryrun'
    return 0
  fi
  if ! command -v openssl >/dev/null 2>&1; then
    log_error "openssl não encontrado e --password-hash não foi informado."
    log_error "Gere o hash você mesmo (ex.: mkpasswd -m sha-512) e passe --password-hash."
    exit 1
  fi
  GENERATED_PASSWORD="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | cut -c1-14)"
  PASSWORD_HASH="$(openssl passwd -6 "$GENERATED_PASSWORD")"
  log_ok "Senha aleatória gerada para o usuário '${USERNAME}' (anote!): ${GENERATED_PASSWORD}"
  log_warn "Troque esta senha após o primeiro login: passwd"
}

# Senha do ROOT (hash crypt, opcional). Sem ela, o root fica BLOQUEADO —
# comportamento padrão (e o mais seguro). Com ela, o root é habilitado na
# instalação: late-command (chpasswd -e) no alvo. Nunca aceitamos senha em
# TEXTO PURO:
# `chpasswd -e` e o d-i esperam um hash crypt, e um texto puro aqui viraria
# "senha = o texto" — falha que só apareceria no primeiro login.
resolve_root_password() {
  if [[ -z "$ROOT_PASSWORD_HASH" ]]; then
    log_info "Root fica BLOQUEADO (padrão). Use --root-password-hash para habilitá-lo."
    return 0
  fi
  if [[ "$ROOT_PASSWORD_HASH" != \$* || "$ROOT_PASSWORD_HASH" == *[[:space:]]* ]]; then
    log_error "--root-password-hash não parece um hash crypt (esperado \$6\$…): recebi algo com espaço ou sem \$."
    log_error "Gere com: mkpasswd -m sha-512   (ou openssl passwd -6)."
    exit 1
  fi
  log_ok "Root habilitado com hash crypt (via --root-password-hash)."
}

# ---------------------------------------------------------------------------
# Escolher a entrada do SHA256SUMS oficial
# ---------------------------------------------------------------------------
# DOIS detalhes que só aparecem com o arquivo real na mão (e que quebraram a
# geração da ISO Ubuntu — o build morria com `exit code 22` do curl, sem
# nenhuma pista do motivo):
#
#   1. O SHA256SUMS do Ubuntu marca o modo BINÁRIO com `*` antes do nome (mesmo
#      formato do `md5sum -b`). O do Debian não usa marcador. Sem remover o `*`,
#      a URL montada era `.../24.04/*ubuntu-24.04.5-...iso` → HTTP 404.
#   2. O SHA256SUMS do Ubuntu lista TODAS as point releases (24.04.3, .4, .5…) e
#      também as variantes desktop/wsl. Pegar a PRIMEIRA entrada casada baixaria
#      a versão mais VELHA; o correto é a MAIOR.
#
# As duas funções imprimem "sha256 nome" (nome já normalizado) ou nada.

# Normaliza o nome do arquivo vindo de um SHA256SUMS.
normalize_iso_name() {
  local n="$1"
  n="${n#\*}"   # marcador de modo binário (`md5sum -b`)
  n="${n#./}"   # prefixo "./" usado por alguns SHA256SUMS
  printf '%s' "$n"
}

# Escolhe, entre as linhas que casam com o padrão, a de MAIOR versão.
pick_iso_entry() {
  local sums_file="$1" pattern="$2"
  awk -v p="$pattern" '
    { n=$2; sub(/^\*/, "", n); sub(/^\.\//, "", n)
      if (n ~ p) print $1 " " n }
  ' "$sums_file" | sort -k2,2 -V | tail -1
}

# Mesma ideia, mas para um nome EXATO (usado com --iso-url).
pick_iso_entry_by_name() {
  local sums_file="$1" want="$2"
  awk -v w="$want" '
    { n=$2; sub(/^\*/, "", n); sub(/^\.\//, "", n)
      if (n == w) { print $1 " " n; exit } }
  ' "$sums_file"
}

# ---------------------------------------------------------------------------
# Obter a ISO oficial
# ---------------------------------------------------------------------------
acquire_iso() {
  section "ISO de origem"
  mkdir -p "${WORK_DIR}/cache"

  if [[ -n "$INPUT_ISO" ]]; then
    [[ -f "$INPUT_ISO" ]] || { log_error "ISO não encontrada: ${INPUT_ISO}"; exit 1; }
    ISO_PATH="$(cd "$(dirname "$INPUT_ISO")" && pwd)/$(basename "$INPUT_ISO")"
    log_info "Usando ISO local: ${ISO_PATH}"
    if [[ -n "$EXPECTED_SHA" ]]; then
      verify_sha "$ISO_PATH" "$EXPECTED_SHA" || exit 1
    else
      log_warn "Nenhum --sha256 informado: a integridade da ISO não será verificada."
    fi
    return 0
  fi

  # Descobrir a versão atual e o checksum oficial, para não confiar em URL fixa.
  local default_base="$UBUNTU_CD_BASE_DEFAULT"
  local sum_pattern="$UBUNTU_ISO_PATTERN"

  local base_url="${ISO_URL:-$default_base}"
  if [[ -n "$ISO_URL" ]]; then
    # URL completa foi dada; usamos o nome do arquivo e, se possível, o SHA256SUMS.
    base_url="$(dirname "$ISO_URL")"
  fi

  local sums_url="${base_url}/SHA256SUMS"
  local sums_file="${WORK_DIR}/cache/SHA256SUMS"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] baixaria ${sums_url} e escolheria a MAIOR versão que casa com /${sum_pattern}/"
    ISO_PATH="${WORK_DIR}/cache/${DISTRO}-${ROLE}.iso"
    EXPECTED_SHA="(do SHA256SUMS oficial)"
    return 0
  fi

  log_info "Baixando a lista de checksums: ${sums_url}"
  if ! curl -fsSL --retry 3 -o "$sums_file" "$sums_url"; then
    log_error "Falha ao baixar ${sums_url}"
    log_error "Use --iso /caminho/para/a-iso.iso para trabalhar offline."
    exit 1
  fi

  local entry
  if [[ -n "$ISO_URL" ]]; then
    entry="$(pick_iso_entry_by_name "$sums_file" "$(basename "$ISO_URL")")"
  else
    entry="$(pick_iso_entry "$sums_file" "$sum_pattern")"
  fi

  if [[ -z "$entry" ]]; then
    log_error "Não encontrei um arquivo que casa com /${sum_pattern}/ em ${sums_url}"
    exit 1
  fi

  EXPECTED_SHA="${entry%% *}"
  local filename="${entry##* }"
  filename="$(normalize_iso_name "$filename")"
  # Defesa em profundidade: as funções acima já normalizam, mas um nome com
  # `*`, espaço ou `/` geraria uma URL inválida e um 404 disfarçado de
  # `exit 22` do curl — erro que custou uma sessão inteira para ser achado.
  # Melhor falhar aqui, dizendo exatamente o que está errado.
  if [[ ! "$filename" =~ ^[A-Za-z0-9._-]+\.iso$ ]]; then
    log_error "Nome de ISO suspeito no SHA256SUMS: '${filename}'"
    log_error "Esperado um nome de arquivo simples terminando em .iso."
    exit 1
  fi
  log_info "Alvo: ${filename} (sha256 ${EXPECTED_SHA:0:16}…)"

  local dest="${WORK_DIR}/cache/${filename}"
  if [[ -f "$dest" ]] && verify_sha_quiet "$dest" "$EXPECTED_SHA"; then
    log_info "ISO já está no cache e confere com o SHA256SUMS (reutilizando)."
  else
    log_info "Baixando ${base_url}/${filename} (≈ 2.6 GB)…"
    run "Download da ISO" curl -fL --retry 3 --progress-bar -o "${dest}.part" "${base_url}/${filename}"
    mv "${dest}.part" "$dest"
    verify_sha "$dest" "$EXPECTED_SHA" || { log_error "Checksum não confere. Download corrompido?"; exit 1; }
  fi
  ISO_PATH="$dest"
}

verify_sha() {
  local file="$1" want="$2"
  log_info "Verificando SHA256 de $(basename "$file")…"
  local got; got="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$got" == "$want" ]]; then
    log_ok "SHA256 confere."
    return 0
  fi
  log_error "SHA256 divergente!"
  log_error "  esperado: $want"
  log_error "  obtido:   $got"
  return 1
}
verify_sha_quiet() {
  local got; got="$(sha256sum "$1" | awk '{print $1}')"
  [[ "$got" == "$2" ]]
}

# ---------------------------------------------------------------------------
# Layout: preparação do stage (Ubuntu)
# ---------------------------------------------------------------------------
UBUNTU_STAGE=
UBUNTU_GRUB_BIOS=""
UBUNTU_GRUB_EFI=""

# Ubuntu: NÃO extrai a ISO inteira. Só tiramos os grub.cfg (que serão editados e
# devolvidos via `-map`) e montamos um stage com o que será injetado. Assim os
# setores de boot do Ubuntu (El Torito BIOS + imagem EFI + MBR híbrido)
# permanecem byte a byte idênticos aos da ISO oficial.
prepare_ubuntu() {
  section "Preparação do stage (Ubuntu)"
  UBUNTU_STAGE="${WORK_DIR}/stage"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] validaria o layout (casper/ + boot/grub/grub.cfg) e extrairia os grub.cfg"
    UBUNTU_GRUB_BIOS="${UBUNTU_STAGE}/grub-bios.cfg"
    UBUNTU_GRUB_EFI="${UBUNTU_STAGE}/grub-efi.cfg"
    return 0
  fi

  rm -rf "$UBUNTU_STAGE"
  mkdir -p "$UBUNTU_STAGE"

  # Validação do layout: a ISO Ubuntu Server tem casper/ (o sistema live) e o
  # menu do GRUB em boot/grub/grub.cfg. Sem casper/ não é uma ISO live do
  # Ubuntu e o autoinstall.yaml não seria encontrado pelo Subiquity.
  local listing
  listing="$(xorriso -indev "$ISO_PATH" -find /casper -maxdepth 1 -type d 2>/dev/null || true)"
  if [[ -z "$listing" ]]; then
    log_error "Layout inesperado: não encontrei /casper na ISO."
    log_error "--distro ubuntu exige uma ISO **Ubuntu Server live** (releases.ubuntu.com)."
    exit 1
  fi

  UBUNTU_GRUB_BIOS="${UBUNTU_STAGE}/grub-bios.cfg"
  UBUNTU_GRUB_EFI="${UBUNTU_STAGE}/grub-efi.cfg"

  if ! xorriso -osirrox on -indev "$ISO_PATH" -extract /boot/grub/grub.cfg "$UBUNTU_GRUB_BIOS" 2>/dev/null; then
    log_error "Não consegui extrair /boot/grub/grub.cfg da ISO."
    exit 1
  fi
  chmod u+w "$UBUNTU_GRUB_BIOS"
  log_ok "Menu do GRUB (BIOS) extraído: ${UBUNTU_GRUB_BIOS}"

  if xorriso -osirrox on -indev "$ISO_PATH" -extract /EFI/boot/grub.cfg "$UBUNTU_GRUB_EFI" 2>/dev/null; then
    chmod u+w "$UBUNTU_GRUB_EFI"
    log_ok "Menu do GRUB (UEFI) extraído: ${UBUNTU_GRUB_EFI}"
  else
    rm -f "$UBUNTU_GRUB_EFI"
    UBUNTU_GRUB_EFI=""
    log_info "Sem /EFI/boot/grub.cfg: o UEFI delegará para /boot/grub/grub.cfg (comum)."
  fi
}

inject_project() {
  section "Injeção do projeto"
  # O projeto entra no stage e vai para a ISO via `-map` (o Ubuntu não é
  # reconstruído: só o que muda é mapeado, preservando os setores de boot).
  local base="${UBUNTU_STAGE}"
  local dest="${base}/ai-cpu-os"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${REPO_ROOT} → ${dest} (sem .git, sem iso/work, sem iso/out, sem webui, sem *.iso)"
    return 0
  fi

  mkdir -p "$dest"
  # `webui/` fica de FORA: é ferramenta da máquina que GERA a ISO (quer
  # navegador e não faz nada num sistema já instalado). Levá-la para a mídia só
  # confundiria quem olhasse /opt/ai-cpu-os no alvo.
  tar -C "$REPO_ROOT" -cf - \
      --exclude=./.git \
      --exclude=./iso/work \
      --exclude=./iso/out \
      --exclude=./webui \
      --exclude='./*.iso' \
      . | tar -C "$dest" -xf -

  # Alguns arquivos precisam do bit de execução dentro do sistema instalado.
  chmod +x "${dest}/build.sh" "${dest}/detect-hardware.sh" \
           "${dest}/llama-build.sh" "${dest}/iso/firstboot.sh" \
           "${dest}/families/resolve.sh" "${dest}/mods/apply.sh" 2>/dev/null || true
  chmod +x "${dest}/mods"/*/*.sh "${dest}/roles"/*/*.sh "${dest}/tests"/*.sh 2>/dev/null || true
  log_ok "Projeto copiado para ${dest} ($(du -sh "$dest" | awk '{print $1}'))"
}

# ---------------------------------------------------------------------------
# Modelo embutido na mídia (--iso-model)
# ---------------------------------------------------------------------------
# POR QUE ELE VAI NA MÍDIA: a ISO é air-gapped (decisão da sessão #14). O que
# NÃO pode acontecer é o 1º boot do alvo precisar de rede para buscar o modelo.
# Baixá-lo AGORA, na máquina que gera a ISO, é aceitável — aqui há rede e o
# arquivo fica auditável dentro da mídia, com nome e tamanho conhecidos.
#
# O late-command copia o arquivo para /opt/models no sistema instalado e o
# firstboot.sh o repassa ao papel via AI_MODEL_FILE (sem download).
acquire_model() {
  section "Modelo na mídia (--iso-model ${ISO_MODEL})"

  case "$ISO_MODEL" in
    none|no|"")
      MODEL_SRC=""; MODEL_NAME=""
      log_info "Sem modelo na ISO. O alvo sobe sem modelo; use --model-file para instalar um .gguf depois."
      return 0 ;;
    auto)
      MODEL_NAME="$SUGGESTED_MODEL_NAME"
      local dir="${WORK_DIR}/models"
      MODEL_SRC="${dir}/${MODEL_NAME}"
      if [[ -f "$MODEL_SRC" ]]; then
        log_info "Modelo já baixado (idempotente): ${MODEL_SRC} ($(du -h "$MODEL_SRC" | cut -f1))"
        return 0
      fi
      if [[ $DRY_RUN -eq 1 ]]; then
        MODEL_SRC=""; MODEL_NAME="$SUGGESTED_MODEL_NAME"
        log_info "[dry-run] baixaria ${SUGGESTED_MODEL_URL} para ${dir} (≈1,1 GB)"
        return 0
      fi
      log_info "Baixando o modelo sugerido (≈1,1 GB): ${SUGGESTED_MODEL_URL}"
      run "Criando ${dir}" mkdir -p "$dir"
      if ! download_to "$SUGGESTED_MODEL_URL" "$MODEL_SRC" "o modelo"; then
        MODEL_SRC=""; MODEL_NAME=""
        log_warn "Falha ao baixar o modelo. A ISO será gerada SEM modelo."
        log_warn "Gere com '--iso-model CAMINHO' apontando para um .gguf que você já tem."
        return 0
      fi
      log_ok "Modelo baixado: ${MODEL_SRC} ($(du -h "$MODEL_SRC" | cut -f1))"
      return 0 ;;
  esac

  # Caminho fornecido pelo usuário.
  [[ -f "$ISO_MODEL" ]] \
    || { log_error "--iso-model ${ISO_MODEL}: arquivo não encontrado (use auto, none ou um .gguf)."; exit 1; }
  local magic
  magic="$(head -c 4 "$ISO_MODEL" 2>/dev/null || true)"
  [[ "$magic" == "GGUF" ]] \
    || { log_error "--iso-model ${ISO_MODEL}: não parece um arquivo GGUF (esperado o magic 'GGUF')."; exit 1; }

  MODEL_SRC="$ISO_MODEL"
  MODEL_NAME="$(basename "$ISO_MODEL")"
  log_ok "Modelo do usuário: ${MODEL_SRC} ($(du -h "$MODEL_SRC" | cut -f1)) → ${MODEL_NAME}"
}

# Copia o .gguf para a árvore da ISO (a MESMA que o late-command vai ler em
# /cdrom/models). Sem modelo, não faz nada.
inject_model() {
  [[ -n "$MODEL_SRC" && -n "$MODEL_NAME" ]] || return 0

  local base="${UBUNTU_STAGE}"
  local dest="${base}/models"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${MODEL_SRC} → ${dest}/${MODEL_NAME}"
    return 0
  fi

  mkdir -p "$dest"
  run "Copiando o modelo para a ISO" cp -f "$MODEL_SRC" "${dest}/${MODEL_NAME}"
  log_ok "Modelo na mídia: /models/${MODEL_NAME} ($(du -h "${dest}/${MODEL_NAME}" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Fonte do llama.cpp na midia (--iso-source)
# ---------------------------------------------------------------------------
# O llama.cpp e COMPILADO no 1o boot (decisao firmada: e o unico jeito de o
# binario sair com o -march da familia realmente detectada). O tarball na midia
# faz esse passo -- o mais demorado do 1o boot -- funcionar SEM rede, e pina a
# versao: o que sera compilado e exatamente o que esta na midia.
#
# Nao extraimos o tarball aqui nem no late-command: o proprio `llama-build.sh
# --source` ja sabe extrair um .tar.gz (inclusive tratando o diretorio de topo
# do tarball do GitHub). Menos codigo, um caminho so.
acquire_source() {
  section "Fonte do llama.cpp (--iso-source ${ISO_SOURCE})"

  SOURCE_FILE=""
  SOURCE_NAME=""
  case "$ISO_SOURCE" in
    none|no|"")
      log_info "Sem fonte na ISO: o 1o boot vai precisar de rede para clonar o llama.cpp."
      return 0 ;;
    auto)
      SOURCE_NAME="$ISO_SOURCE_FILENAME"
      local dir="${WORK_DIR}/llama-src"
      SOURCE_FILE="${dir}/${SOURCE_NAME}"
      if [[ -f "$SOURCE_FILE" ]]; then
        log_info "Fonte ja baixada (idempotente): ${SOURCE_FILE} ($(du -h "$SOURCE_FILE" | cut -f1))"
        return 0
      fi
      if [[ $DRY_RUN -eq 1 ]]; then
        log_info "[dry-run] baixaria ${SUGGESTED_SOURCE_URL} para ${dir}"
        return 0
      fi
      log_info "Baixando a fonte do llama.cpp (master): ${SUGGESTED_SOURCE_URL}"
      run "Criando ${dir}" mkdir -p "$dir"
      if ! download_to "$SUGGESTED_SOURCE_URL" "$SOURCE_FILE" "a fonte do llama.cpp"; then
        SOURCE_FILE=""; SOURCE_NAME=""
        log_warn "Falha ao baixar a fonte. A ISO sera gerada SEM ela (o 1o boot vai exigir rede)."
        log_warn "Use '--iso-source CAMINHO' com um .tar.gz que voce ja tenha."
        return 0
      fi
      log_ok "Fonte baixada: ${SOURCE_FILE} ($(du -h "$SOURCE_FILE" | cut -f1))"
      ;;
    *)
      # Caminho fornecido pelo usuario: validamos ANTES de montar a ISO.
      [[ -f "$ISO_SOURCE" ]] \
        || { log_error "--iso-source ${ISO_SOURCE}: arquivo nao encontrado (use auto, none ou um .tar.gz)."; exit 1; }
      [[ "$ISO_SOURCE" == *.tar.gz || "$ISO_SOURCE" == *.tgz || "$ISO_SOURCE" == *.tar.xz || "$ISO_SOURCE" == *.tar ]] \
        || { log_error "--iso-source ${ISO_SOURCE}: precisa ser um .tar.gz/.tgz/.tar.xz/.tar."; exit 1; }
      SOURCE_FILE="$ISO_SOURCE"
      SOURCE_NAME="$ISO_SOURCE_FILENAME"
      ;;
  esac

  [[ -n "$SOURCE_FILE" ]] || return 0

  # Sanidade: um tarball do llama.cpp tem CMakeLists.txt na raiz (ou num
  # diretorio de topo). Sem isso, o 1o boot descobriria o problema depois de
  # instalar -- tarde e caro.
  local listing
  listing="$(tar -tf "$SOURCE_FILE" 2>/dev/null | head -200 || true)"
  if [[ -z "$listing" ]]; then
    log_error "--iso-source: ${SOURCE_FILE} nao e um tarball legivel."
    exit 1
  fi
  if ! printf '%s
' "$listing" | grep -qE '(^|/)CMakeLists\.txt$'; then
    log_warn "${SOURCE_FILE}: nao achei CMakeLists.txt nas primeiras entradas do tarball."
    log_warn "Se nao for o fonte do llama.cpp, o 1o boot vai falhar ao compilar."
  fi
  log_ok "Fonte do llama.cpp para a midia: ${SOURCE_FILE} ($(du -h "$SOURCE_FILE" | cut -f1))"
}

# Copia o tarball da fonte para dentro da ISO.
inject_source() {
  [[ -n "$SOURCE_FILE" && -n "$SOURCE_NAME" ]] || return 0

  local base="${UBUNTU_STAGE}"
  local dest="${base}/${SOURCE_NAME}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${SOURCE_FILE} -> ${dest}"
    return 0
  fi

  run "Copiando a fonte para a ISO" cp -f "$SOURCE_FILE" "$dest"
  log_ok "Fonte na midia: /${SOURCE_NAME} ($(du -h "$dest" | cut -f1))"
}

# ---------------------------------------------------------------------------
# Repositório apt local (--iso-repo) — o que torna a instalação offline possível
# ---------------------------------------------------------------------------
# Codename do Ubuntu a partir do número da release. '' = não sei (não bloqueia,
# só avisa): inventar um codename novo faria o build mentir.
ubuntu_codename_for_version() {
  case "$1" in
    22.04) echo jammy ;;
    24.04) echo noble ;;
    24.10) echo oracular ;;
    25.04) echo plucky ;;
    25.10) echo questing ;;
    26.04) echo resolute ;;
    *)     echo "" ;;
  esac
}

# Codename da BASE lido do PRÓPRIO arquivo da ISO (`.disk/info`), com a tabela
# acima como reserva. POR QUE NÃO SÓ A TABELA (bug medido na sessão #36): a
# tabela envelhece. Numa ISO 26.04 ela devolvia "", o build caía em "não sei o
# codename → não confiro a release" e — pior — SEGUIA montando o repositório
# local sem conferir nada: .deb de outra release entrariam na mídia. Lendo do
# arquivo, o guarda funciona para QUALQUER release, inclusive as futuras.
# Formato da linha: Ubuntu-Server 24.04.5 LTS "Noble Numbat" - Release amd64
iso_base_codename() {
  local tmp="" info="" cn=""
  [[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || { ubuntu_codename_for_version "$(iso_release_version)"; return 0; }
  if command -v xorriso >/dev/null 2>&1; then
    tmp="$(mktemp -d "${WORK_DIR:-/tmp}/.disk-info.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$tmp" ]] && xorriso -osirrox on -indev "$ISO_PATH" \
         -extract /.disk/info "${tmp}/info" >/dev/null 2>&1; then
      info="$(head -1 "${tmp}/info" 2>/dev/null || true)"
      # pega o primeiro termo entre aspas e usa minúsculo: "Noble Numbat" -> noble
      cn="$(printf '%s' "$info" | sed -nE 's/.*"([A-Za-z]+)[^"]*".*/\1/p' | tr 'A-Z' 'a-z')"
    fi
    [[ -n "$tmp" ]] && rm -rf "$tmp"
  fi
  if [[ -n "$cn" ]]; then
    printf '%s' "$cn"
  else
    ubuntu_codename_for_version "$(iso_release_version)"
  fi
}

# Release da ISO base (do --iso-url, ou do padrão). '' = não sei dizer.
iso_release_version() {
  # A versão da BASE é o que importa (os .deb têm de casar com ela).
  # BUG CORRIGIDO (sessão #36): com `--iso <arquivo>`, o ISO_URL é vazio e a
  # função caía no DEFAULT (24.04) — então quem montava a ISO de 26.04 a partir
  # de um arquivo local via "Release incompatível" e o `--iso-repo auto`
  # descartava o repositório local SEM AVISO ÚTIL, deixando a instalação
  # dependente de rede. O nome do arquivo carrega a versão; é de lá que ela sai.
  if [[ -n "$INPUT_ISO" ]]; then
    # ubuntu-26.04.1-live-server-amd64.iso -> 26.04
    # (um nome fora do padrão devolve vazio: quem chama trata como "não sei")
    printf '%s' "$(basename "$INPUT_ISO")" \
      | sed -nE 's#^ubuntu-([0-9]+\.[0-9]+)(\.[0-9]+)?-.*#\1#p'
    return 0
  fi
  printf '%s' "${ISO_URL:-$UBUNTU_CD_BASE_DEFAULT}" \
    | sed -nE 's#.*releases\.ubuntu\.com/([0-9]+\.[0-9]+).*#\1#p'
}

# Linha de sources.list do repositório local (formato "flat": índice na raiz,
# `./` como suite). `trusted=yes` porque um repositório local não é assinado —
# e assinar exigiria gerenciar chave no alvo, o que não agrega aqui.
apt_local_source_line() {
  # SEM repositório na mídia, a linha tem de ser VAZIA — é isso que faz o
  # bloco inteiro sumir (do YAML). Devolver uma linha com caminho
  # vazio inseriria uma fonte inútil e inválida.
  [[ -n "$APT_REPO_PATH_REL" ]] || return 0
  # O caminho é o da MÍDIA MONTADA (ex.: file:///cdrom/apt-repo) — não o nome
  # relativo à raiz da ISO. Foi o harness de teste que pegou esta confusão.
  printf 'deb [trusted=yes] file://%s/%s ./' "$APT_REPO_MOUNT" "$APT_REPO_PATH_REL"
}

# Gera o índice (Packages/Packages.gz) a partir dos .deb de um diretório.
# Não usamos dpkg-scanpackages de propósito: ele vive no dpkg-dev, que não está
# em toda máquina de build. O `control` do próprio .deb já traz Depends,
# Provides, Pre-Depends etc., então basta despejá-lo e acrescentar os campos de
# localização (Filename/Size/SHA256) que o apt exige.
build_repo_index() {
  local dir="$1" deb rel size hash n=0
  : > "${dir}/Packages"
  while IFS= read -r deb; do
    [[ -n "$deb" ]] || continue
    rel="${deb#"$dir"/}"
    size="$(stat -c %s "$deb")"
    hash="$(sha256sum "$deb" | cut -d' ' -f1)"
    {
      dpkg-deb -f "$deb"
      printf 'Filename: %s\nSize: %s\nSHA256: %s\n\n' "$rel" "$size" "$hash"
    } >> "${dir}/Packages"
    n=$((n + 1))
  done < <(find "$dir" -name '*.deb' -type f | sort)
  gzip -9c "${dir}/Packages" > "${dir}/Packages.gz"

  # `Release` do repositório local. O apt do instalador EXIGE um Release mesmo
  # num repositório "flat" quando a fonte é a mídia (`file:///cdrom/apt-repo`),
  # e sem ele o `apt-get update` do curtin retorna **100** ("The repository
  # ... does not have a Release file"), derrubando o `apt-config` no meio da
  # instalação — descoberto ao bootar uma ISO de verdade (o repositório na
  # mídia nunca tinha sido exercitado; é o "aceite do instalador para o repo
  # local" que o JOURNAL § 5.2 marcava como suposição). Os checksums referem-se
  # ao índice na raiz (layout flat); `trusted=yes` na fonte dispensa assinatura.
  # O codename da BASE: é ele que o alvo compara e que o apt espera ver.
  if [[ -z "${REPO_SUITE:-}" ]]; then
    REPO_SUITE="$(iso_base_codename)"
    [[ -n "$REPO_SUITE" ]] || REPO_SUITE="stable"
  fi
  {
    printf 'Origin: ai-cpu-os\n'
    printf 'Label: ai-cpu-os\n'
    # `Suite`/`Codename` REAIS (não `./`). Dois motivos, ambos medidos:
    #  * o `late-command` recusa um repositório de outra release comparando o
    #    `Codename` com o do alvo — com `./` a comparação falhava SEMPRE e o
    #    repositório da mídia era silenciosamente descartado (a ISO "air-gapped"
    #    então dependia de rede no 1º boot e falhava com rc=100);
    #  * ferramentas que auditam o repositório (`apt-get`, `reprepro`) esperam
    #    um codename de verdade nesse campo.
    printf 'Suite: %s\n' "${REPO_SUITE:-stable}"
    printf 'Codename: %s\n' "${REPO_SUITE:-stable}"
    printf 'Date: %s\n' "$(date -Ru)"
    printf 'Architectures: amd64 all\n'
    printf 'Components: ./\n'
    printf 'Description: ai-cpu-os - repositorio apt local (midia air-gapped)\n'
    printf 'MD5Sum:\n'
    printf ' %s %16s %s\n' "$(md5sum "${dir}/Packages" | cut -d' ' -f1)" "$(stat -c %s "${dir}/Packages")" Packages
    printf ' %s %16s %s\n' "$(md5sum "${dir}/Packages.gz" | cut -d' ' -f1)" "$(stat -c %s "${dir}/Packages.gz")" Packages.gz
    printf 'SHA256:\n'
    printf ' %s %16s %s\n' "$(sha256sum "${dir}/Packages" | cut -d' ' -f1)" "$(stat -c %s "${dir}/Packages")" Packages
    printf ' %s %16s %s\n' "$(sha256sum "${dir}/Packages.gz" | cut -d' ' -f1)" "$(stat -c %s "${dir}/Packages.gz")" Packages.gz
  } > "${dir}/Release"

  # Sanidade do índice: sem estes campos o apt descarta a entrada em silêncio.
  local missing
  missing="$(awk '/^Package: /{p=1} /^Filename: /{f=1} /^Size: /{s=1}
                    /^$/{if(p&&!(f&&s)) print "entrada sem Filename/Size"; p=f=s=0}' \
                  "${dir}/Packages" | wc -l)"
  [[ "$missing" -eq 0 ]] \
    || { log_error "Índice gerado em ${dir} tem ${missing} entrada(s) inválida(s)."; return 1; }

  REPO_PKG_COUNT="$n"
  REPO_SIZE_MB=$(( $(du -sm "$dir" | cut -f1) ))
  log_ok "Índice do repositório: ${n} pacotes, ${REPO_SIZE_MB} MB"
  return 0
}

# ---------------------------------------------------------------------------
# Filtrar nomes SEM candidato antes de baixar
# ---------------------------------------------------------------------------
# POR QUE ISSO EXISTE (medido, sessão #19): `apt-get download a b c` **ABORTA O
# LOTE INTEIRO** se UM dos nomes não tiver candidato — não baixa nem os que são
# perfeitamente válidos. Medido na máquina de desenvolvimento:
#
#     apt-get download git PACOTE-QUE-NAO-EXISTE jq   →  rc=100, ZERO arquivos
#
# com `git` e `jq` perdidos como dano colateral.
#
# O fecho do `apt-cache depends --recurse` inclui pacotes **virtuais** (sem
# candidato), e QUAIS são depende da release do host. No runner (Ubuntu 24.04)
# havia pelo menos um, e foi ele que fez o CI falhar com "Pacote pedido está
# AUSENTE no repositório: gnupg/jq/git" — três pacotes sem nada de errado, que
# estavam no mesmo lote da isca. O `|| true` engolia o resto em silêncio.
#
# `LC_ALL=C` é obrigatório: no locale pt-BR o rótulo é "Candidato:" e o parser
# não acharia nada (e devolveria lista vazia).
packages_with_candidate() {
  local nomes="$1"
  [[ -n "$nomes" ]] || return 0
  # shellcheck disable=SC2086
  LC_ALL=C apt-cache policy $nomes 2>/dev/null | awk '
    /^[^[:space:]]/ { nome = $1; sub(/:$/, "", nome); next }
    /^[[:space:]]+Candidate: / {
      if ($2 == "(none)") next
      if (nome != "") print nome
      next
    }
  '
}

# Baixa os .deb (pacotes + fecho de dependências) para o diretório final.
download_repo_packages() {
  local dir="$1" list="$2" out

  # Fecho de dependências. `--no-*` desliga o que não é necessário para o
  # pacote FUNCIONAR (recomendados/sugeridos/quebras), que só engordariam a
  # mídia. Pre-Depends é mantido: omiti-lo quebraria instalações.
  out="$(LC_ALL=C apt-cache depends --recurse --no-recommends --no-suggests \
           --no-conflicts --no-breaks --no-replaces --no-enhances \
           $list 2>/dev/null \
         | grep -E '^[a-zA-Z0-9][a-zA-Z0-9+._-]*$' | sort -u)"

  [[ -n "$out" ]] \
    || { log_error "Não consegui calcular as dependências (apt-cache vazio)."; return 1; }

  local n_bruto; n_bruto="$(printf '%s\n' "$out" | wc -l)"

  # Tira os nomes sem candidato ANTES de baixar (ver packages_with_candidate).
  local filtrado; filtrado="$(packages_with_candidate "$out")"
  if [[ -z "$filtrado" ]]; then
    # Degrada, não quebra (Regra 13-a): se a saída do apt-cache policy não for
    # o que o parser espera, seguimos com o fecho inteiro — o fallback um-a-um
    # lá embaixo ainda protege contra a isca.
    log_warn "O filtro de candidatos não devolveu nada; não vou descartar o fecho."
    log_warn "(Um nome virtual no meio ainda é tolerado pelo fallback um-a-um.)"
    filtrado="$out"
  else
    local n_filtrado; n_filtrado="$(printf '%s\n' "$filtrado" | wc -l)"
    if (( n_filtrado < n_bruto )); then
      log_info "Fecho: ${n_bruto} nomes, ${n_filtrado} com candidato ($(( n_bruto - n_filtrado )) virtual/ausente descartado antes do download)."
    fi
  fi

  log_info "Fecho de dependências: $(printf '%s\n' "$filtrado" | wc -l) pacotes (pedidos: $(printf '%s' "$list" | wc -w))"
  log_info "Baixando os .deb em ${dir} (isto pode demorar)…"

  mkdir -p "$dir/pool"

  local -a arr=()
  mapfile -t arr <<< "$filtrado"
  local total=${#arr[@]} i=0 falhas=0
  local -a falhados=()

  # `Acquire::Retries=3`: o apt tenta de novo em erro transitório de rede.
  # Sem isto, um 5xx momentâneo do mirror entra como "pacote ausente" — que é
  # indistinguível de "pacote não existe" no log e já custou uma sessão.
  # Lotes de 25 (medido: 5× mais rápido que 1-a-1) com fallback um-a-um no lote
  # que falhar, para que a perda fique restrita ao nome realmente ruim.
  while (( i < total )); do
    local lote=( "${arr[@]:i:25}" )
    if ! ( cd "$dir/pool" && apt-get download -o Acquire::Retries=3 "${lote[@]}" >/dev/null 2>&1 ); then
      local p
      for p in "${lote[@]}"; do
        ( cd "$dir/pool" && apt-get download -o Acquire::Retries=3 "$p" >/dev/null 2>&1 ) \
          || { falhas=$(( falhas + 1 )); falhados+=( "$p" ); }
      done
    fi
    i=$(( i + 25 ))
  done

  local got; got="$(find "$dir/pool" -name '*.deb' -type f | wc -l)"
  # NÃO engolir a falha em silêncio (era o que o `|| true` fazia): sem isto o
  # dano colateral ficava invisível e só reaparecia como "pacote pedido ausente".
  if (( falhas > 0 )); then
    log_warn "${falhas} pacote(s) do fecho não puderam ser baixados:"
    local j
    for j in "${falhados[@]:0:10}"; do log_warn "  - ${j}"; done
    if (( falhas > 10 )); then log_warn "  (mostrando 10 de ${falhas})"; fi
  fi
  log_info "${got} .deb baixados."
  return 0
}

# Lista (numa linha) os pacotes PEDIDOS que NÃO estão no diretório. Vazio =
# completo. Existe para o retry: refazer só o que faltou custa segundos, em vez
# de repetir 330 MB de download.
# Aceita as duas formas: diretório com índice (grep no Packages) ou diretório
# CRU de .deb (find) — é o que permite ao --dry-run validar um --iso-repo DIR.
repo_missing_packages() {
  local dir="$1" list="$2" p out=""
  for p in $list; do
    if [[ -f "${dir}/Packages" ]] && grep -q "^Package: ${p}$" "${dir}/Packages"; then
      continue
    elif [[ -n "$(find "$dir" -name "${p}_*.deb" -type f -print -quit 2>/dev/null)" ]]; then
      continue
    fi
    out+="${p} "
  done
  printf '%s' "$out"
}

# Confere que cada pacote PEDIDO existe no repositório. O fecho pode ter falhas
# toleradas; os pedidos, não — sem eles a ISO não cumpre a promessa offline.
check_repo_completeness() {
  local dir="$1" list="$2"
  local missing
  missing="$(repo_missing_packages "$dir" "$list")"
  if [[ -n "$missing" ]]; then
    local p
    for p in $missing; do
      # Cuidado com a palavra: "AUSENTE" afirmava que o pacote não existe, o
      # que é FALSO quando a causa foi um 404/queda de rede — e mandou uma
      # sessão inteira caçar um bug inexistente em `git`. Diga o que se sabe:
      # ele não entrou no repositório que estamos montando.
      log_error "Pacote pedido não entrou no repositório local: ${p} (veja os avisos do apt acima)"
    done
    log_error "Repositório incompleto — o alvo precisaria de rede."
    return 1
  fi
  return 0
}

# Obtém o repositório (baixando ou usando um diretório) e o materializa em
# ${WORK_DIR}/apt-repo. Nada é embutido na ISO por esta função; isso é o
# inject_repo.
acquire_repo() {
  section "Repositório apt local (--iso-repo ${ISO_REPO})"

  REPO_DIR_LOCAL=""
  APT_REPO_PATH=""
  case "$ISO_REPO" in
    none|no|"")
      log_info "Sem repositório local: o alvo precisará de rede para instalar pacotes"
      log_info "(o modelo e o fonte do llama.cpp vêm da mídia de qualquer forma)."
      return 0 ;;
  esac

  local pkgs="${ISO_REPO_PACKAGES:-$DEFAULT_REPO_PACKAGES}"
  local dest="${WORK_DIR}/${ISO_REPO_DIRNAME}"

  # ---------------------------------------------------------------------------
  # `auto` DEGRADA, nunca aborta.
  # ---------------------------------------------------------------------------
  # Regra aprendida na marra (CI vermelho na sessão #18): um valor DEFAULT não
  # pode fazer o build falhar. `--iso-repo` nasce em `auto`, então qualquer
  # invocação existente passaria a falhar — mesmo sendo um pedido razoável.
  # Quando não dá para montar um repositório CORRETO, avisamos alto e seguimos
  # sem ele: a ISO continua válida (só passa a precisar de rede para instalar
  # pacotes).
  #
  # Quem pediu um caminho explícito (`--iso-repo DIR`) e errou o caminho
  # continua recebendo erro fatal: aí a entrada é do usuário e é corrigível.

  # Um repositório montado com os .deb de OUTRA release produz versões que não
  # casam com a base da ISO — e o modo de falha é uma instalação quebrada.
  if [[ "$ISO_REPO" == "auto" && $ISO_REPO_ALLOW_MISMATCH -eq 0 ]]; then
    local ver want have
    ver="$(iso_release_version)"
    want="$(iso_base_codename)"
    have="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")"
    if [[ -z "$want" ]]; then
      log_warn "Não sei o codename do Ubuntu ${ver:-<?>}; não vou conferir a release."
      log_warn "Se a sua máquina não for a MESMA release da ISO, os .deb podem não casar."
    elif [[ -z "$have" ]]; then
      log_warn "Não consegui ler /etc/os-release; não vou conferir a release."
    elif [[ "$have" != "$want" ]]; then
      # WARN (não ERROR): isto NÃO aborta — a ISO é gerada sem o repositório.
      # Usar log_error aqui confundiria quem lê o log do CI procurando falha.
      log_warn "Release incompatível: a ISO é Ubuntu ${ver} (${want}) e esta máquina é '${have}'."
      log_warn "Os .deb baixados aqui não casam com a base da ISO. Três saídas:"
      log_warn "  1) rode o build numa ${want} (ou numa VM/container ${want});"
      log_warn "  2) use --iso-url para a ISO da SUA release (${have}), e aí os .deb casam;"
      log_warn "  3) baixe os .deb por fora e passe --iso-repo CAMINHO."
      log_warn "(ou --iso-repo-allow-mismatch, que monta o repo mesmo assim — teste, não produção.)"
      log_warn "Seguindo SEM repositório local: a ISO valerá, mas o alvo precisará de rede."
      ISO_REPO="none"
      return 0
    else
      log_info "Release confere: ${have} (Ubuntu ${ver})."
    fi
  fi

  # Validações que são SOMENTE LEITURA rodam também no --dry-run: o objetivo
  # dele é pegar cedo um --iso-repo apontando para o lugar errado.
  if [[ "$ISO_REPO" != "auto" ]]; then
    [[ -d "$ISO_REPO" ]] \
      || { log_error "--iso-repo ${ISO_REPO}: não existe (use auto, none ou um diretório)."; exit 1; }
    local nfound
    nfound="$(find "$ISO_REPO" -name '*.deb' -type f | wc -l)"
    (( nfound > 0 )) \
      || { log_error "--iso-repo ${ISO_REPO}: nenhum .deb encontrado."; exit 1; }
    log_info "Diretório de .deb: ${ISO_REPO} (${nfound} arquivos)"
    if ! check_repo_completeness "$ISO_REPO" "$pkgs"; then
      log_error "Um --iso-repo assim geraria uma ISO que NÃO instala offline."
      exit 1
    fi
  fi

  REPO_DIR_LOCAL="$dest"
  APT_REPO_PATH_REL="$ISO_REPO_DIRNAME"
  APT_REPO_PATH="${APT_REPO_MOUNT}/${ISO_REPO_DIRNAME}"

  # (a partir daqui o repositório VAI ser embutido)
  if [[ $DRY_RUN -eq 1 ]]; then
    if [[ "$ISO_REPO" == "auto" ]]; then
      log_info "[dry-run] baixaria o fecho de dependências de: ${pkgs}"
    else
      log_info "[dry-run] copiaria ${ISO_REPO} → ${dest} e geraria o índice"
    fi
    return 0
  fi

  if [[ "$ISO_REPO" != "auto" ]]; then
    # Diretório fornecido pelo usuário: copiamos os .deb para a árvore final
    # (previsível e sem escrever no diretório dele).
    run "Preparando ${dest}" mkdir -p "$dest/pool"
    run "Copiando os .deb" cp -a "${ISO_REPO}"/*.deb "$dest/pool/"
    build_repo_index "$dest" || exit 1
    check_repo_completeness "$dest" "$pkgs" || exit 1
  else
    download_repo_packages "$dest" "$pkgs" || exit 1
    build_repo_index "$dest" || exit 1

    if ! check_repo_completeness "$dest" "$pkgs"; then
      # SEGUNDA TENTATIVA, só do que faltou. Por que existe: uma falha
      # transitória de rede é indistinguível de "pacote não existe" no log, e
      # no CI isso derrubou o build com "Pacote pedido está AUSENTE: git" — um
      # pacote que simplesmente existe. Refazer apenas os ausentes custa
      # segundos e converte a falha intermitente em sucesso.
      local faltando p saida
      local -a ainda=()
      faltando="$(repo_missing_packages "$dest" "$pkgs")"
      log_warn "Refazendo o download de: ${faltando} (segunda tentativa)"

      # (i) ÍNDICE FRESCO antes de repetir. Se a falha foi um `404` do espelho
      #     (a lista aponta para uma versão que já saiu do archive, o que
      #     acontece em virada de point release), repetir o download com a
      #     MESMA lista falha igual — `Acquire::Retries` não conserta uma lista
      #     inválida. Foi o que o run #16 mostrou: o retry gastou ~4 s e
      #     reproduziu o erro idêntico. Degrada com aviso (Regra 13-a) se não
      #     houver rede.
      if ! run "apt-get update (índice fresco para a 2ª tentativa)" \
               apt-get update -qq; then
        log_warn "apt-get update falhou (sem rede?); seguindo com o índice atual."
      fi

      # (ii) Um a UM **e com a saída do apt logada**. Descartar o erro
      #      (`>/dev/null 2>&1`) foi o que deixou o run #16 ilegível: o log
      #      dizia "pacote ausente" de um pacote que existe, e a CAUSA real
      #      (o que o apt respondeu) não tinha ido para lugar nenhum.
      # shellcheck disable=SC2086
      for p in ${faltando}; do
        if ! saida="$( cd "${dest}/pool" && apt-get download -o Acquire::Retries=5 "$p" 2>&1 )"; then
          ainda+=( "$p" )
          log_warn "  ${p}: $(printf '%s' "$saida" | tail -n 1)"
        fi
      done
      if (( ${#ainda[@]} > 0 )); then
        log_warn "Ainda faltando depois da 2ª tentativa: ${ainda[*]}"
      fi

      build_repo_index "$dest" || exit 1
      check_repo_completeness "$dest" "$pkgs" || exit 1
    fi
  fi

  if (( REPO_SIZE_MB > ISO_REPO_BUDGET_MB )); then
    log_warn "Repositório com ${REPO_SIZE_MB} MB — acima do orçamento de aviso (${ISO_REPO_BUDGET_MB} MB)."
    log_warn "A ISO final pode passar do tamanho esperado. Use --iso-repo-packages para reduzir."
  fi

  log_ok "Repositório pronto para embutir: ${REPO_PKG_COUNT} pacotes, ${REPO_SIZE_MB} MB"
}

# Copia a árvore do repositório para dentro da ISO. Sem repo, não faz nada.
inject_repo() {
  [[ -n "$REPO_DIR_LOCAL" && -n "$APT_REPO_PATH_REL" ]] || return 0

  local base="${UBUNTU_STAGE}"
  local dest="${base}/${APT_REPO_PATH_REL}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${REPO_DIR_LOCAL} → ${dest}"
    return 0
  fi

  [[ -f "${REPO_DIR_LOCAL}/Packages.gz" ]] \
    || { log_error "Índice ausente em ${REPO_DIR_LOCAL}/Packages.gz — não vou embutir um repo quebrado."; exit 1; }

  mkdir -p "$dest"
  run "Copiando o repositório para a ISO" cp -a "${REPO_DIR_LOCAL}/." "$dest/"
  log_ok "Repositório na mídia: /${APT_REPO_PATH_REL}/ (Packages.gz + $(find "$dest" -name '*.deb' | wc -l) .deb)"
}

# Expande o marcador @@APT_LOCAL_SOURCES@@ no autoinstall: uma fonte EXTRA
# (seção `sources` do curtin) ou nada, quando não há repositório na mídia.
# Sintetizar YAML "por bloco" é a mesma técnica de expand_packages_block — e o
# bloco desaparecer por completo é o que mantém o YAML válido nos dois casos.
expand_apt_local_block() {
  local f="$1" line
  line="$(apt_local_source_line)"

  awk -v line="$line" '
    /^@@APT_LOCAL_SOURCES@@$/ {
      # A fonte local NÃO entra no apt do INSTALADOR. Descoberto ao bootar a
      # ISO de verdade: o curtin roda o `apt-get update` DENTRO de um chroot no
      # alvo, onde `/cdrom` não está montado, então `file:///cdrom/apt-repo`
      # (mesmo com Release) derruba o `apt-config` com exit 100 ("does not have
      # a Release file"). O repositório é carregado para o ALVO pelo
      # late-command.sh (/opt/apt-repo) e usado no PRIMEIRO BOOT. Marcador
      # removido de propósito — ver docs/ISO.md § 3.1.
      next
    }
    { print }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}
# ---------------------------------------------------------------------------
# Templates: substituição de marcadores e gravação
# ---------------------------------------------------------------------------
# Escapa o que o `sed` trataria como sintaxe no lado da substituição.
_sed_repl() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'; }

# Bloco de armazenamento do autoinstall (YAML em flow — mantém a substituição
# por `sed` numa única linha, sem precisar de um processador de YAML).
storage_layout_line() {
  if [[ -n "$DISK" ]]; then
    printf 'layout: {name: direct, match: {path: %s}}' "$DISK"
  else
    printf 'layout: {name: direct}'
  fi
}

# "a b  c" → uma sequência em BLOCO do YAML, uma entrada por linha:
#
#   packages:
#     - a
#     - b
#     - c
#
# Não usamos a forma em flow (`packages: [a, b, c]`) de propósito: com dez
# pacotes a linha passa de 120 colunas e o yamllint (correto) reclama — e o
# usuário pode passar uma lista ainda maior em --extra-packages. Em bloco o
# tamanho da lista nunca vira problema.
expand_packages_block() {
  local f="$1"
  awk -v list="$EXTRA_PACKAGES" '
    /^packages: @@PACKAGES_BLOCK@@$/ {
      print "packages:"
      n = split(list, a, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (a[i] != "") print "  - " a[i]
      next
    }
    { print }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
}

# Bloco `network:` do autoinstall (e o MESMO conteúdo vira o netplan do alvo,
# copiado de /ai-cpu-os-boot da mídia pelo late-command — uma fonte de verdade só).
#
# Por que `match: name: "en*"` em vez do nome da interface: no momento de gerar
# a ISO não se sabe qual placa a máquina terá. O glob cobre os nomes previsíveis
# (`enp5s0`, `eno1`, `enp1s0`) e o `eth*` cobre máquinas antigas. Quando o
# usuário sabe o nome (caso típico do IP fixo), ele passa --network-interface e
# o bloco fica nominal.
network_yaml_block() {
  [[ "$NETWORK_MODE" == "none" ]] && return 0

  printf 'network:\n'
  printf '  version: 2\n'
  printf '  renderer: networkd\n'
  printf '  ethernets:\n'

  if [[ "$NETWORK_MODE" == "static" ]]; then
    local addr="${NET_IP%%/*}" prefix="${NET_IP##*/}"
    local dns_yaml
    dns_yaml="$(printf '%s' "$NET_DNS" | sed -e 's/,/, /g')"
    if [[ -n "$NET_IFACE" ]]; then
      printf '    %s:\n' "$NET_IFACE"
    else
      printf '    lan:\n'
      printf '      match:\n'
      printf '        name: "en*"\n'
    fi
    printf '      addresses: [%s/%s]\n' "$addr" "$prefix"
    printf '      routes:\n'
    printf '        - to: default\n'
    printf '          via: %s\n' "$NET_GATEWAY"
    printf '      nameservers:\n'
    printf '        addresses: [%s]\n' "$dns_yaml"
    printf '      optional: true\n'
    return 0
  fi

  # DHCP (auto/dhcp)
  if [[ -n "$NET_IFACE" ]]; then
    printf '    %s:\n' "$NET_IFACE"
    printf '      dhcp4: true\n'
    printf '      dhcp6: false\n'
    printf '      optional: true\n'
  else
    # Duas definições por glob: se a máquina tiver en* E eth*, as duas recebem
    # DHCP — que é o desejado num DHCP (e `optional: true` evita boot travado).
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

# Expande o marcador @@NETWORK_SECTION@@ no autoinstall. No modo `none` o bloco
# INTEIRO some (não dá para emitir `network:` sem conteúdo: viraria `null`).
expand_network_block() {
  local f="$1" block
  block="$(mktemp)"
  network_yaml_block > "$block"
  awk -v block="$block" '
    /^@@NETWORK_SECTION@@$/ {
      while ((getline l < block) > 0) print l
      close(block)
      next
    }
    { print }
  ' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
  rm -f "$block"
}
# Substitui tokens @@NOME@@ nos templates (autoinstall e ai-cpu-os-boot).
subst_template() {
  local src="$1" dst="$2"
  local hash_esc root_hash_esc store_esc
  hash_esc="$(_sed_repl "$PASSWORD_HASH")"
  root_hash_esc="$(_sed_repl "$ROOT_PASSWORD_HASH")"
  store_esc="$(_sed_repl "$(storage_layout_line)")"
  sed \
    -e "s|@@DISTRO@@|${DISTRO}|g" \
    -e "s|@@ROLE@@|${ROLE}|g" \
    -e "s|@@FAMILY@@|${FAMILY}|g" \
    -e "s|@@FIRSTBOOT_REBOOT@@|${FIRSTBOOT_REBOOT}|g" \
    -e "s|@@SERIAL_CONSOLE@@|${SERIAL_CONSOLE}|g" \
    -e "s|@@ISO_BUILD@@|${ISO_BUILD_ID}|g" \
    -e "s|@@USERNAME@@|${USERNAME}|g" \
    -e "s|@@USER_FULLNAME@@|${USER_FULLNAME}|g" \
    -e "s|@@HOSTNAME@@|${SYS_HOSTNAME}|g" \
    -e "s|@@PASSWORD_HASH@@|${hash_esc}|g" \
    -e "s|@@ROOT_PASSWORD_HASH@@|${root_hash_esc}|g" \
    -e "s|@@LOCALE@@|${LOCALE}|g" \
    -e "s|@@LANG@@|${LANG_CODE}|g" \
    -e "s|@@COUNTRY@@|${COUNTRY}|g" \
    -e "s|@@KEYMAP@@|${KEYMAP}|g" \
    -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
    -e "s|@@GRUB_WITH_OTHER_OS@@|${GRUB_WITH_OTHER_OS}|g" \
    -e "s|@@EXTRA_PACKAGES@@|${EXTRA_PACKAGES}|g" \
    -e "s|@@ISO_MODEL@@|${MODEL_NAME}|g" \
    -e "s|@@LLAMA_SRC_NAME@@|${SOURCE_NAME}|g" \
    -e "s|@@APT_REPO_PATH@@|${APT_REPO_PATH}|g" \
    -e "s|@@APT_PRIMARY_URI@@|${APT_PRIMARY_URI}|g" \
    -e "s|@@STORAGE_LAYOUT@@|${store_esc}|g" \
    -e "s|@@NETWORK_MODE@@|${NETWORK_MODE}|g" \
    -e "s|@@NET_IFACE@@|${NET_IFACE}|g" \
    -e "s|@@NET_IP@@|${NET_IP}|g" \
    -e "s|@@NET_IP_ADDR@@|${NET_IP_ADDR}|g" \
    -e "s|@@NET_PREFIX@@|${NET_PREFIX_EFF}|g" \
    -e "s|@@NET_GATEWAY@@|${NET_GATEWAY}|g" \
    -e "s|@@NET_NETMASK@@|${NET_NETMASK}|g" \
    -e "s|@@NET_DNS@@|${NET_DNS}|g" \
    -e "s|@@NET_DNS_SPACE@@|${NET_DNS_SPACE}|g" \
    "$src" > "$dst"
}

# Grava os templates COMUNS aos dois distros (o late-command e o serviço de
# primeiro boot são compartilhados — eles rodam no sistema instalado).
inject_common_templates() {
  local dest="$1"
  mkdir -p "$dest"
  subst_template "${ISO_DIR}/common/late-command.sh"      "${dest}/late-command.sh"
  subst_template "${ISO_DIR}/common/firstboot.sh"         "${dest}/firstboot.sh"
  cp "${ISO_DIR}/common/ai-cpu-os-firstboot.service"      "${dest}/ai-cpu-os-firstboot.service"
  chmod 0755 "${dest}/late-command.sh" "${dest}/firstboot.sh"
  chmod 0644 "${dest}/ai-cpu-os-firstboot.service"
}

# Rede de segurança: se algum marcador REAL sobrou, a instalação não funciona.
# (Verificamos apenas os nomes esperados — comentários podem conter o formato,
#  então um grep genérico por arrobas daria falso positivo.)
# Retorna 1 (não aborta) para que o autoteste possa acumular falhas.
check_no_leftover_tokens() {
  local -a required_tokens=(
    DISTRO ROLE FAMILY FIRSTBOOT_REBOOT SERIAL_CONSOLE ISO_BUILD USERNAME USER_FULLNAME HOSTNAME PASSWORD_HASH ROOT_PASSWORD_HASH
    LOCALE KEYMAP TIMEZONE EXTRA_PACKAGES PACKAGES_BLOCK STORAGE_LAYOUT ISO_MODEL
    APT_REPO_PATH APT_LOCAL_SOURCES APT_PRIMARY_URI LLAMA_SRC_NAME
    NETWORK_SECTION NETWORK_MODE NET_IFACE NET_IP NET_GATEWAY NET_DNS
  )
  local t leftover=0
  for t in "${required_tokens[@]}"; do
    if grep -q "@@${t}@@" "$@" 2>/dev/null; then
      log_error "Marcador não substituído: @@${t}@@"
      leftover=1
    fi
  done
  if [[ $leftover -ne 0 ]]; then
    log_error "Isso indica um bug no build-iso.sh. Abortando para não gerar uma ISO quebrada."
    return 1
  fi
  return 0
}

inject_templates() {
  section "Configuração de instalação (ubuntu)"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] gravaria ${UBUNTU_STAGE}/autoinstall.yaml e ${UBUNTU_STAGE}/ai-cpu-os-boot/*"
    log_info "[dry-run] disco: ${DISK:-<não fixado>} · papel: ${ROLE} · família: ${FAMILY} · usuário: ${USERNAME}"
    return 0
  fi

  subst_template "${ISO_DIR}/autoinstall/autoinstall.yaml" "${UBUNTU_STAGE}/autoinstall.yaml"
  # A lista de pacotes vira uma sequência em bloco do YAML (ver a função).
  expand_packages_block "${UBUNTU_STAGE}/autoinstall.yaml"
  # Idem para o repositório local: a fonte extra entra — ou some por completo.
  expand_apt_local_block "${UBUNTU_STAGE}/autoinstall.yaml"
  # A rede: o bloco `network:` entra (dhcp/static) ou desaparece por inteiro.
  expand_network_block "${UBUNTU_STAGE}/autoinstall.yaml"
  chmod 0644 "${UBUNTU_STAGE}/autoinstall.yaml"

  inject_common_templates "${UBUNTU_STAGE}/ai-cpu-os-boot"
  # O MESMO bloco vira o netplan do sistema instalado (copiado pelo
  # late-command): instalador e alvo não divergem.
  if [[ "$NETWORK_MODE" != "none" ]]; then
    network_yaml_block > "${UBUNTU_STAGE}/ai-cpu-os-boot/ai-cpu-os-netplan.yaml"
    chmod 0644 "${UBUNTU_STAGE}/ai-cpu-os-boot/ai-cpu-os-netplan.yaml"
  fi
  check_no_leftover_tokens "${UBUNTU_STAGE}/autoinstall.yaml" \
                          "${UBUNTU_STAGE}/ai-cpu-os-boot/late-command.sh" \
                          "${UBUNTU_STAGE}/ai-cpu-os-boot/firstboot.sh" || exit 1
  log_ok "autoinstall.yaml e ai-cpu-os-boot/* gravados no stage (marcadores OK)."
  log_info "Storage: $(storage_layout_line)"
}

# ---------------------------------------------------------------------------
# Boot (GRUB): descobrimos o kernel/initrd do
# sistema live (casper/) e acrescentamos uma entrada automática ao menu.
# ---------------------------------------------------------------------------
_casper_exists() {
  [[ -n "$(xorriso -indev "$ISO_PATH" -find "/casper/$1" -type f 2>/dev/null || true)" ]]
}

detect_casper_paths() {
  local n
  KERNEL_PATH=""; INITRD_PATH=""
  if [[ $DRY_RUN -eq 1 ]]; then
    KERNEL_PATH="/casper/vmlinuz"; INITRD_PATH="/casper/initrd"
    log_info "[dry-run] descobriria o kernel/initrd do sistema live em /casper"
    return 0
  fi
  for n in vmlinuz vmlinuz.efi; do
    _casper_exists "$n" && { KERNEL_PATH="/casper/${n}"; break; }
  done
  for n in initrd initrd.gz initrd.lz; do
    _casper_exists "$n" && { INITRD_PATH="/casper/${n}"; break; }
  done
  if [[ -z "$KERNEL_PATH" || -z "$INITRD_PATH" ]]; then
    log_error "Não encontrei o kernel/initrd do instalador em /casper da ISO."
    exit 1
  fi
  log_info "Kernel: ${KERNEL_PATH} · initrd: ${INITRD_PATH}"
}

# Args extra de kernel quando o console serial está habilitado: sem isto, o
# instalador e o primeiro boot não aparecem no log serial (tela virtual, que
# num teste headless não existe).
kernel_args_extra() {
  if [[ "$SERIAL_CONSOLE" == "yes" ]]; then
    printf 'console=ttyS0,115200'
  fi
}
# Acrescenta timeout/default + a menuentry automática ao fim de um grub.cfg.
# `autoinstall` é o parâmetro de kernel que liga o modo não interativo; o
# `autoinstall.yaml` é achado sozinho na raiz da mídia (ver o cabeçalho do
# template em iso/autoinstall/autoinstall.yaml).
#
# `--id ai-cpu-os-auto` NÃO é decorativo: `set default` casa por id OU por
# título, e o título é "Instalar ai-cpu-os (…)" — sem o `--id` o GRUB não acha
# a entrada, cai para a 0 (a interativa "Try or Install Ubuntu Server") e a
# instalação automática NUNCA acontece (sem autoinstall, sem console serial).
# Descoberto ao bootar a primeira ISO de verdade: o GRUB subia a entrada
# interativa e o teste de VM ficava mudo.
append_grub_ai_entry() {
  local f="$1"
  cat >> "$f" <<EOF

# ---------------------------------------------------------------------------
# ai-cpu-os: entrada de boot automática (inserida por iso/build-iso.sh)
# ---------------------------------------------------------------------------
set timeout=10
set default="ai-cpu-os-auto"
menuentry "Instalar ai-cpu-os (automatico${DISK:+, APAGA ${DISK}})" --id ai-cpu-os-auto {
    set gfxpayload=keep
    linux   ${KERNEL_PATH} autoinstall quiet $(kernel_args_extra) ---
    initrd  ${INITRD_PATH}
}
EOF
}

patch_boot_ubuntu() {
  section "Boot (Ubuntu/GRUB)"

  detect_casper_paths

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] acrescentaria 'set default=ai-cpu-os-auto' + menuentry com"
    log_info "         '${KERNEL_PATH} autoinstall quiet ---' em /boot/grub/grub.cfg (e no do UEFI, se houver)"
    return 0
  fi

  append_grub_ai_entry "$UBUNTU_GRUB_BIOS"
  log_ok "Entrada automática acrescentada em /boot/grub/grub.cfg (BIOS)."

  if [[ -n "$UBUNTU_GRUB_EFI" ]]; then
    append_grub_ai_entry "$UBUNTU_GRUB_EFI"
    log_ok "Entrada automática acrescentada em /EFI/boot/grub.cfg (UEFI)."
  fi

  log_info "O menu continua acessível: escolha outra entrada para instalar manualmente."
}

detect_volume_id() {
  # Geramos um volume id próprio, determinístico e válido pelas regras do
  # ISO9660 (maiúsculas, dígitos e '_', até 32 caracteres). Reaproveitar o
  # volume id original é arriscado: pode ter espaços e o do Ubuntu tem
  # minúsculas e pontos, que o xorriso pode recusar no `-V`.
  printf '%s' "AI_CPU_OS_${DISTRO}_${ROLE}" \
    | tr '[:lower:]' '[:upper:]' \
    | tr -c 'A-Z0-9_' '_' \
    | tr -s '_' \
    | cut -c1-32
}
# Ubuntu: remonta com `-indev/-outdev -map`, ou seja, PARTINDO da ISO oficial e
# apenas sobrepondo o que mudou. É a diferença de fundo em relação ao caminho
# (o caminho antigo extraía a árvore e reconstruía com mkisofs): assim os setores de
# boot do Ubuntu — El Torito BIOS, imagem EFI e MBR híbrido — ficam
# byte a byte iguais aos da ISO oficial, sem depender de mtools nem de
# isohdpfx.bin.
repack_iso_ubuntu() {
  local -a args=(
    -indev "$ISO_PATH"
    -outdev "$OUT_ISO"
    # `replay` (e NÃO `keep`): o Ubuntu guarda a imagem UEFI como imagem El
    # Torito OCULTA, fora da árvore ISO9660. O `keep` só mantém a *referência*
    # do catálogo — a imagem em si "precisa ser adicionada por -map/-add" (doc
    # do xorriso) e, por ser oculta, não entra → a ISO sai ~6 MB menor, o
    # `efi.img` vira 1 bloco e o MBR protetor (copiado verbatim) aponta para
    # além do fim → "Read start address ... larger than readable blocks" e
    # **exit 32 depois de a ISO já ter sido escrita**. O `replay` reexecuta os
    # comandos que o `-report_system_area cmd` propõe (re-anexa a partição EFI
    # via `--interval:imported_iso`, restaura o MBR do GRUB) e produz uma ISO
    # coerente com o novo tamanho. Medido: keep → exit 32, efi 1 bloco;
    # replay → exit 0, efi 2540 blocos. Ver docs/ISO.md § 4.5c.
    -boot_image any replay
    -volid "$VOLUME_ID"
    -map "${UBUNTU_STAGE}/ai-cpu-os"        /ai-cpu-os
    -map "${UBUNTU_STAGE}/ai-cpu-os-boot"   /ai-cpu-os-boot
    -map "${UBUNTU_STAGE}/autoinstall.yaml" /autoinstall.yaml
    -map "$UBUNTU_GRUB_BIOS"                /boot/grub/grub.cfg
  )

  if [[ -n "$UBUNTU_GRUB_EFI" ]]; then
    args+=(-map "$UBUNTU_GRUB_EFI" /EFI/boot/grub.cfg)
  fi

  # O modelo, a fonte do llama.cpp e o repositório apt entram na mídia por -map
  # explícito. Isto é o preço do caminho Ubuntu mapear SÓ o que muda (em vez de
  # reconstruir a árvore): o que não for mapeado fica no
  # `stage` e **não** na ISO. Sem estes três, a ISO se dizia air-gapped mas não
  # tinha o modelo/fonte/repo — o `verify-iso.sh` reprovou exatamente isso
  # ("o autoinstall aponta para um repositório local, mas /apt-repo NÃO está na
  # mídia"). Os destinos casam com o que o late-command lê: SRC=/cdrom, então
  # /models/<nome>, /<fonte>.tar.gz e /apt-repo.
  if [[ -n "$MODEL_NAME" ]]; then
    args+=(-map "${UBUNTU_STAGE}/models" /models)
  fi
  if [[ -n "$SOURCE_NAME" ]]; then
    args+=(-map "${UBUNTU_STAGE}/${SOURCE_NAME}" "/${SOURCE_NAME}")
  fi
  if [[ -n "$APT_REPO_PATH_REL" ]]; then
    args+=(-map "${UBUNTU_STAGE}/${APT_REPO_PATH_REL}" "/${APT_REPO_PATH_REL}")
  fi

  # O md5sum.txt original descreve a mídia ANTES das nossas alterações. O
  # Subiquity não o usa no autoinstall, mas um arquivo obsoleto confunde quem
  # for inspecionar a ISO. Removemos apenas se ele existir (senão o xorriso
  # reclama de um caminho inexistente).
  if [[ $DRY_RUN -eq 0 ]] \
     && [[ -n "$(xorriso -indev "$ISO_PATH" -find /md5sum.txt -type f 2>/dev/null || true)" ]]; then
    # O `--` FECHA a lista de caminhos do `-rm`. Sem ele, o xorriso lê o
    # `-commit`/`-end` seguinte como mais um caminho a remover, emite
    # "SORRY: Cannot find path '-commit'", tolera mas devolve **exit 32** — e
    # derruba o build DEPOIS de a ISO ter sido escrita (o sintoma é uma ISO
    # válida em disco + exit 32, não um erro legível).
    args+=(-rm /md5sum.txt --)
    log_info "md5sum.txt será removido (ficaria obsoleto após as alterações)."
  fi

  args+=(-commit -end)

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] xorriso ${args[*]}"
    return 0
  fi

  run "Gerando a ISO (update in-place)" xorriso "${args[@]}"
  log_ok "ISO gerada: ${OUT_ISO}"
}

verify_output() {
  section "Verificação"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] verificaríamos a ISO gerada (config de instalação, projeto, boot)."
    return 0
  fi
  [[ -f "$OUT_ISO" ]] || { log_error "ISO de saída não existe: ${OUT_ISO}"; exit 1; }

  log_info "Tamanho: $(du -h "$OUT_ISO" | awk '{print $1}')"
  log_info "SHA256:  $(sha256sum "$OUT_ISO" | awk '{print $1}')"

  local listing
  listing="$(xorriso -indev "$OUT_ISO" -find /ai-cpu-os-boot -type f -exec echo 2>/dev/null || true)"
  if [[ -n "$listing" ]]; then
    log_ok "Conteúdo de /ai-cpu-os-boot na ISO:"
    printf '    | %s\n' $listing
  else
    log_warn "Não consegui listar /ai-cpu-os-boot na ISO gerada (verifique manualmente)."
  fi

  if [[ -n "$(xorriso -indev "$OUT_ISO" -find /ai-cpu-os/build.sh -type f 2>/dev/null || true)" ]]; then
    log_ok "Projeto presente em /ai-cpu-os na ISO."
  else
    log_warn "Não confirmei /ai-cpu-os na ISO gerada."
  fi

  # O autoinstall é o que faz a instalação ser automática — vale confirmar que
  # chegou na ISO.
  if [[ -n "$(xorriso -indev "$OUT_ISO" -find /autoinstall.yaml -type f 2>/dev/null || true)" ]]; then
    log_ok "autoinstall.yaml presente na raiz da ISO (é achado ao lado de casper/)."
  else
    log_error "autoinstall.yaml AUSENTE: a instalação não seria automática."
    exit 1
  fi

  # O menu de boot precisa ter a nossa entrada padrão.
  local grub_txt grub_tmp
  # Extrair para um arquivo temporário, NÃO para /dev/stdout: o xorriso não
  # entrega o conteúdo de forma confiável em /dev/stdout (a captura vinha
  # vazia e gerava um falso "Não confirmei a entrada 'ai-cpu-os-auto'" mesmo
  # com a entrada presente).
  grub_tmp="$(mktemp)"
  if xorriso -osirrox on -indev "$OUT_ISO" \
       -extract /boot/grub/grub.cfg "$grub_tmp" >/dev/null 2>&1; then
    grub_txt="$(cat "$grub_tmp" 2>/dev/null || true)"
  fi
  rm -f "$grub_tmp"
  if [[ "$grub_txt" == *ai-cpu-os-auto* ]]; then
    log_ok "Menu do GRUB com a entrada automática 'ai-cpu-os-auto'."
  else
    log_warn "Não confirmei a entrada 'ai-cpu-os-auto' no menu do GRUB."
  fi
}
check_templates() {
  section "Autoteste dos templates"
  local tmp rc=0
  tmp="$(mktemp -d)"

  PASSWORD_HASH="${PASSWORD_HASH:-\$6\$EXEMPLO\$autoteste}"
  ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-\$6\$EXEMPLO\$root}"

  local variant disk dir netmode
  for variant in com-disco sem-disco; do
    if [[ "$variant" == "com-disco" ]]; then disk="/dev/nvme0n1"; else disk=""; fi
    DISK="$disk"

    # Três modos de rede, porque cada um gera um YAML DIFERENTE (e o modo
    # `none` precisa fazer o bloco `network:` desaparecer por inteiro).
    for netmode in auto static none; do
      NETWORK_MODE="$netmode"
      if [[ "$netmode" == "static" ]]; then
        NET_IP="192.168.1.50/24"; NET_GATEWAY="192.168.1.1"; NET_DNS="1.1.1.1,8.8.8.8"
        NET_IP_ADDR="192.168.1.50"; NET_PREFIX_EFF="24"
        NET_NETMASK="255.255.255.0"; NET_DNS_SPACE="1.1.1.1 8.8.8.8"
      else
        NET_IP=""; NET_GATEWAY=""; NET_DNS=""
        NET_IP_ADDR=""; NET_PREFIX_EFF=""; NET_NETMASK=""; NET_DNS_SPACE=""
      fi

      # O modo `auto` (default) mantém os nomes históricos `com-disco`/
      # `sem-disco` — `tests/test-iso-disk.sh` e quem já inspecionava a árvore
      # com `--keep-templates` dependem deles. Os modos extras ganham sufixo.
      if [[ "$netmode" == "auto" ]]; then
        dir="${tmp}/${variant}"
      else
        dir="${tmp}/${variant}-${netmode}"
      fi
      mkdir -p "$dir"

      subst_template "${ISO_DIR}/autoinstall/autoinstall.yaml" "${dir}/autoinstall.yaml"
      expand_packages_block "${dir}/autoinstall.yaml"
      expand_apt_local_block "${dir}/autoinstall.yaml"
      expand_network_block "${dir}/autoinstall.yaml"
      subst_template "${ISO_DIR}/common/late-command.sh"        "${dir}/late-command.sh"
      subst_template "${ISO_DIR}/common/firstboot.sh"           "${dir}/firstboot.sh"
      if [[ "$NETWORK_MODE" != "none" ]]; then
        network_yaml_block > "${dir}/ai-cpu-os-netplan.yaml"
      fi

      log_info "variante '${variant}' · rede '${netmode}': storage = $(storage_layout_line)"
      log_info "              packages =${EXTRA_PACKAGES:+ }${EXTRA_PACKAGES}"

      if check_no_leftover_tokens "${dir}/autoinstall.yaml" "${dir}/late-command.sh" \
                                  "${dir}/firstboot.sh"; then
        log_ok "  marcadores: todos substituídos"
      else
        rc=1
      fi

      # Coerência da rede: o bloco tem de existir (e ser o pedido) ou sumir.
      if [[ "$netmode" == "none" ]]; then
        if grep -q '^network:' "${dir}/autoinstall.yaml"; then
          log_error "  rede 'none': o bloco 'network:' deveria ter sumido"
          rc=1
        else
          log_ok "  rede 'none': sem bloco 'network:' (comportamento antigo)"
        fi
      elif [[ "$netmode" == "static" ]]; then
        if grep -q 'addresses: \[192.168.1.50/24\]' "${dir}/ai-cpu-os-netplan.yaml" \
           && grep -q 'via: 192.168.1.1' "${dir}/ai-cpu-os-netplan.yaml"; then
          log_ok "  rede static: addresses + rota default no netplan do alvo"
        else
          log_error "  rede static: netplan do alvo não tem endereço/rota"
          rc=1
        fi
      else
        if grep -q 'dhcp4: true' "${dir}/ai-cpu-os-netplan.yaml"; then
          log_ok "  rede dhcp: dhcp4 no netplan do alvo"
        else
          log_error "  rede dhcp: netplan do alvo sem dhcp4"
          rc=1
        fi
      fi

      if bash -n "${dir}/firstboot.sh" 2>/dev/null; then
        log_ok "  firstboot.sh: sintaxe bash OK"
      else
        log_error "  firstboot.sh: sintaxe bash inválida"
        rc=1
      fi

      if sh -n "${dir}/late-command.sh" 2>/dev/null; then
        log_ok "  late-command.sh: sintaxe POSIX sh OK"
      else
        log_error "  late-command.sh: sintaxe POSIX sh inválida"
        rc=1
      fi

      # O hash do root vai para o script como LITERAL, e todo hash crypt tem
      # `$` (`$6$sal$resto`). Se o marcador ficar entre ASPAS DUPLAS no
      # template, o shell expande `$6` ao ler o arquivo e — sob `set -u` — o
      # late-command.sh morre com exit 2 ANTES de copiar qualquer coisa. Foi o
      # que já travou a ISO Debian (sessão #35). A sintaxe (`sh -n`) NÃO pega
      # isso: só avaliação
      # de verdade pega, então aqui o valor é lido por um shell com `-u`.
      local hash_line got_hash
      hash_line="$(grep -m1 '^ROOT_PASSWORD_HASH=' "${dir}/late-command.sh" || true)"
      got_hash="$(sh -u -c "${hash_line}; printf %s \"\$ROOT_PASSWORD_HASH\"" 2>/dev/null || true)"
      if [[ "$got_hash" == "$ROOT_PASSWORD_HASH" ]]; then
        log_ok "  late-command.sh: hash do root chega intacto ao shell (\$ preservado)"
      else
        log_error "  late-command.sh: o hash do root é CORROMPIDO pelo shell"
        log_error "    esperado: ${ROOT_PASSWORD_HASH}"
        log_error "    obtido:   ${got_hash:-<vazio/erro>}"
        log_error "    (o marcador precisa de ASPAS SIMPLES no template)"
        rc=1
      fi

      if command -v yamllint >/dev/null 2>&1; then
        if yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/autoinstall.yaml" >/dev/null 2>&1; then
          log_ok "  autoinstall.yaml: YAML válido"
        else
          log_error "  autoinstall.yaml: YAML inválido"
          yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/autoinstall.yaml" || true
          rc=1
        fi
        if [[ -f "${dir}/ai-cpu-os-netplan.yaml" ]]; then
          if yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/ai-cpu-os-netplan.yaml" >/dev/null 2>&1; then
            log_ok "  netplan do alvo: YAML válido"
          else
            log_error "  netplan do alvo: YAML inválido"
            yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/ai-cpu-os-netplan.yaml" || true
            rc=1
          fi
        fi
      else
        log_warn "  yamllint ausente: o YAML do autoinstall NÃO foi validado."
      fi
    done
  done

  NETWORK_MODE="auto"
  DISK=""
  if [[ $KEEP_TEMPLATES -eq 1 ]]; then
    # Não remove a árvore e imprime o caminho de forma MECÂNICA (a linha
    # `TEMPLATES_DIR=…` é o que o teste lê para inspecionar o YAML gerado —
    # o autoteste valida a sintaxe, mas só um teste consegue checar SEMÂNTICA,
    # como "sem --disk, o layout não pode restringir disco").
    log_info "TEMPLATES_DIR=${tmp}"
    log_warn "Árvore dos templates MANTIDA em ${tmp} (--keep-templates)."
  else
    rm -rf "$tmp" 2>/dev/null || true
  fi
  if [[ -n "$MODEL_NAME" ]]; then
    log_info "Modelo embutido: /models/${MODEL_NAME} (copiado para /opt/models no 1º boot)"
  else
    log_warn "ISO SEM modelo: o alvo sobe sem LLM. Instale um com --model-file (ver docs/ISO.md § 3.1)."
  fi
  if [[ $rc -eq 0 ]]; then
    log_ok "Autoteste dos templates: OK."
  else
    log_error "Autoteste dos templates: FALHOU."
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ISO_BUILD_ID="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ISO_PATH=""
VOLUME_ID=""
KERNEL_PATH=""
INITRD_PATH=""

main() {
  parse_args "$@"

  printf '%b' "$C_BOLD"
  printf '=================================================\n'
  printf '   ai-cpu-os · gerador de ISO de instalação\n'
  printf '=================================================\n'
  printf '%b' "$C_RESET"

  log_info "dry_run=${DRY_RUN} · distro=${DISTRO} · papel=${ROLE} · família=${FAMILY} · disco=${DISK:-<auto>} · saída=${OUT_ISO}"
  log_warn "A ISO gerada APAGA o disco indicado durante a instalação. Teste em VM primeiro!"

  # Autoteste dos templates: não gera ISO, não precisa de disco nem de root.
  if [[ $CHECK_TEMPLATES -eq 1 ]]; then
    check_templates
    local rc_tpl=$?
    selftest_iso_tools || rc_tpl=1
    exit $rc_tpl
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_warn "Sem root: a remontagem com xorriso costuma funcionar, mas pode falhar em alguns ambientes."
  fi

  # ANTES de tocar em qualquer coisa no disco: um build por vez. Dois builds no
  # mesmo --work-dir brigam pelos .part do modelo/fonte e o segundo morre com um
  # "mv: cannot stat" que não explica nada (ver acquire_build_lock).
  acquire_build_lock

  check_deps
  resolve_password
  resolve_root_password
  acquire_iso

  # O modelo é obtido ANTES de montar a árvore: um erro (arquivo errado,
  # magic inválido) falha cedo, sem gastar extração/remontagem.
  acquire_model
  # A fonte do llama.cpp e o que faz o 1o boot compilar sem rede.
  acquire_source
  # Idem para o repositório: conferir a release e baixar os .deb é caro, e um
  # erro aqui precisa aparecer ANTES da remontagem da ISO.
  acquire_repo

  # A ordem importa: o stage precisa existir antes de injetar o projeto, e o
  # patch de boot precisa do kernel/initrd que só é conhecido depois dele.
  prepare_ubuntu
  inject_project
  inject_model
  inject_source
  inject_repo
  inject_templates
  patch_boot_ubuntu

  VOLUME_ID="$(detect_volume_id)"
  log_info "Volume ID da ISO: '${VOLUME_ID}'"

  repack_iso_ubuntu
  verify_output

  section "Resumo"
  log_ok "ISO: ${OUT_ISO}"
  log_info "Distro base: ubuntu (única suportada — ADR-001)"
  log_info "Papel gravado: ${ROLE} (auto = detecta o hardware no primeiro boot)"
  log_info "Família gravada: ${FAMILY} (auto = detecta o hardware no primeiro boot)"
  if [[ -n "$ROOT_PASSWORD_HASH" ]]; then
    log_info "Usuário: ${USERNAME} (sudo) · root HABILITADO (hash crypt, não exibido)"
  else
    log_info "Usuário: ${USERNAME} (sudo) · root bloqueado"
  fi
  if [[ -n "$MODEL_NAME" ]]; then
    log_info "Modelo embutido: /models/${MODEL_NAME} (o late-command copia para /opt/models)"
  else
    log_warn "ISO SEM modelo: o alvo sobe sem LLM. Instale um depois com --model-file (docs/ISO.md § 3.1)."
  fi
  if [[ -n "$SOURCE_NAME" ]]; then
    log_info "Fonte do llama.cpp na midia: /${SOURCE_NAME} (o 1o boot compila SEM rede)"
  else
    log_warn "ISO SEM fonte do llama.cpp: o 1o boot vai exigir rede para clonar (unico passo online restante)."
  fi
  if [[ -n "$APT_REPO_PATH" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "Repositório apt na mídia: ${APT_REPO_PATH} (dry-run: nada foi gerado)"
    else
      log_info "Repositório apt na mídia: ${APT_REPO_PATH} (${REPO_PKG_COUNT} pacotes, ${REPO_SIZE_MB} MB)"
    fi
  else
    log_warn "ISO SEM repositório apt: instalar pacotes no alvo exigirá rede."
    # O aviso é específico de propósito: sem rede na instalação o `pkgsel`
    # (Debian) e o `ssh: install-server` (Ubuntu) falham EM SILÊNCIO, e o alvo
    # nasce SEM servidor SSH — sem teclado/tela, inacessível. O late-command
    # tenta consertar no fim da instalação, mas só consegue se houver rede.
    log_warn "  ↳ Consequência: um alvo SEM rede na instalação sobe SEM SSH (só console)."
    log_warn "  ↳ Para uma mídia que se basta: --iso-repo auto (leva os .deb na ISO)."
  fi
  if [[ -n "$GENERATED_PASSWORD" ]]; then
    log_warn "SENHA GERADA: ${GENERATED_PASSWORD} — anote agora, não é recuperável daqui."
  fi
  if [[ -n "$DISK" ]]; then
    log_warn "Partição automática apaga: ${DISK}"
  else
    log_warn "Disco não fixado: o instalador usará o primeiro disco disponível."
  fi
  # Rastro no resumo: quem gerou a ISO para OUTRA máquina precisa ver isto na
  # última tela, não no meio de 200 linhas de log. É o modo nº 1 de a instalação
  # automática não acontecer (ver docs/TROUBLESHOOTING.md "SINALIZADO").
  if [[ $DISK_MISSING_ON_BUILD -eq 1 ]]; then
    log_warn "⚠ A mídia sai com o disco ${DISK} FIXADO, e ele não existe aqui."
    log_warn "  No alvo, o Subiquity procura um disco com esse caminho; se não achar,"
    log_warn "  a instalação automática NÃO acontece (sem erro visível). Se a ISO é"
    log_warn "  para outro PC, gere de novo com: --disk auto"
  fi
  log_info "Testar em VM: qemu-system-x86_64 -m 4096 -enable-kvm -cdrom '${OUT_ISO}' -boot d"
  log_info "No sistema instalado, o tuning é aplicado no primeiro boot:"
  log_info "    systemctl status ai-cpu-os-firstboot && cat /var/log/ai-cpu-os-firstboot.log"

  if [[ $NO_VERIFY -eq 0 ]]; then
    run_verify_iso
  fi

  log_info "Teste automatizado de boot (instala + 1º boot; precisa de qemu):"
  log_info "    bash iso/test-vm.sh --iso '${OUT_ISO}' --yes"
  if [[ "$SERIAL_CONSOLE" != "yes" ]]; then
    log_warn "Para o teste de VM enxergar a instalação, gere a ISO com --serial-console."
  fi

  if [[ $KEEP_WORK -eq 0 && $DRY_RUN -eq 0 ]]; then
    log_info "Removendo o diretório de trabalho (${WORK_DIR}); use --keep-work para mantê-lo."
    rm -rf "$WORK_DIR" 2>/dev/null || log_warn "Não consegui remover ${WORK_DIR}."
  fi
}

# ---------------------------------------------------------------------------
# Verificação automática da ISO gerada (delega ao iso/verify-iso.sh)
# ---------------------------------------------------------------------------
# Verificar é barato e somente leitura, então o padrão é verificar. Um FAIL aqui
# é tratado como erro do build: é melhor falhar agora do que entregar uma ISO
# que não instala sozinha.
run_verify_iso() {
  local verifier="${ISO_DIR}/verify-iso.sh"
  if [[ ! -f "$verifier" ]]; then
    log_warn "iso/verify-iso.sh não encontrado; pulando a verificação automática."
    return 0
  fi

  # Em --dry-run nada foi gerado: não há o que verificar.
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] pularia a verificação automática (nenhuma ISO foi gerada)."
    return 0
  fi

  # Cinto de segurança: se por algum motivo a ISO não existe, avisamos em vez de
  # transformar isso num erro confuso vindo do verificador.
  if [[ ! -f "$OUT_ISO" ]]; then
    log_warn "ISO de saída não existe (${OUT_ISO}); nada a verificar."
    return 0
  fi

  section "Verificação automática da ISO"
  local -a args=(--iso "$OUT_ISO" --distro "$DISTRO" --role "$ROLE" --family "$FAMILY")
  if [[ -n "$DISK" ]]; then
    args+=(--disk "$DISK")
  fi

  if bash "$verifier" "${args[@]}"; then
    log_ok "A ISO passou na verificação de conteúdo."
  else
    log_error "A ISO gerada NÃO passou na verificação (iso/verify-iso.sh)."
    log_error "Corrija antes de bootar: veja os [FAIL] acima."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Autoteste (usado pelo CI): monta uma árvore com os templates REAIS e o
# projeto REAL e roda as duas ferramentas sobre ela. Não precisa de xorriso,
# nem de disco, nem de root.
# ---------------------------------------------------------------------------
selftest_iso_tools() {
  section "Autoteste das ferramentas da ISO"
  local tmp rc=0
  tmp="$(mktemp -d)"
  local stage="${tmp}/stage"

  # 1) Os templates, já substituídos (mesmo caminho do build de verdade).
  UBUNTU_STAGE="$stage"
  mkdir -p "${stage}/boot/grub"
  subst_template "${ISO_DIR}/autoinstall/autoinstall.yaml" "${stage}/autoinstall.yaml"
  expand_packages_block "${stage}/autoinstall.yaml"
  expand_apt_local_block "${stage}/autoinstall.yaml"
  expand_network_block "${stage}/autoinstall.yaml"
  inject_common_templates "${stage}/ai-cpu-os-boot"
  if [[ "$NETWORK_MODE" != "none" ]]; then
    network_yaml_block > "${stage}/ai-cpu-os-boot/ai-cpu-os-netplan.yaml"
    chmod 0644 "${stage}/ai-cpu-os-boot/ai-cpu-os-netplan.yaml"
  fi

  # 2) O projeto real (o mesmo tar que o build injeia).
  mkdir -p "${stage}/ai-cpu-os"
  tar -C "$REPO_ROOT" -cf - \
      --exclude=./.git --exclude=./iso/work --exclude=./iso/out \
      --exclude=./webui --exclude='./*.iso' \
      . | tar -C "${stage}/ai-cpu-os" -xf -
  chmod +x "${stage}/ai-cpu-os/build.sh" "${stage}/ai-cpu-os/detect-hardware.sh" \
           "${stage}/ai-cpu-os/llama-build.sh" "${stage}/ai-cpu-os/families/resolve.sh" \
           "${stage}/ai-cpu-os/mods/apply.sh" "${stage}/ai-cpu-os-boot/late-command.sh" \
           "${stage}/ai-cpu-os-boot/firstboot.sh" 2>/dev/null || true

  # 3) A entrada de boot, gerada pela MESMA função do build.
  KERNEL_PATH="/casper/vmlinuz"
  INITRD_PATH="/casper/initrd"
  append_grub_ai_entry "${stage}/boot/grub/grub.cfg"

  # 4) Verificador sobre a árvore (é isto que o CI cobre de verdade).
  log_info "Rodando iso/verify-iso.sh sobre a árvore de teste (--dir)…"
  if bash "${ISO_DIR}/verify-iso.sh" --dir "$stage" --distro ubuntu \
       --disk "$DISK" --role "$ROLE" --family "$FAMILY"; then
    log_ok "verify-iso.sh passou na árvore de teste."
  else
    log_error "verify-iso.sh REPROVOU a árvore de teste — o verificador ou o build estão errados."
    rc=1
  fi

  # 5) E, de propósito, a prova de que o verificador DETECTA problema: apaga o
  #    autoinstall.yaml e exige um FAIL. Um verificador que nunca falha não vale
  #    nada — este é o teste negativo.
  log_info "Teste negativo: removendo o autoinstall.yaml (o verificador deve REPROVAR)…"
  mv "${stage}/autoinstall.yaml" "${stage}/autoinstall.yaml.bak"
  if bash "${ISO_DIR}/verify-iso.sh" --dir "$stage" --distro ubuntu --quiet >/dev/null 2>&1; then
    log_error "verify-iso.sh APROVOU uma árvore sem autoinstall.yaml (falso positivo!)."
    rc=1
  else
    log_ok "verify-iso.sh reprovou corretamente a árvore sem config."
  fi
  mv "${stage}/autoinstall.yaml.bak" "${stage}/autoinstall.yaml"

  rm -rf "$tmp" 2>/dev/null || true

  if [[ $rc -eq 0 ]]; then
    log_ok "Autoteste das ferramentas da ISO: OK."
  else
    log_error "Autoteste das ferramentas da ISO: FALHOU."
  fi
  return $rc
}

# Permite `source iso/build-iso.sh` para carregar as funções sem executar nada
# (útil para testar a substituição de templates isoladamente — é assim que o
# CI exercita o autoinstall.yaml). Mesmo padrão de families/resolve.sh.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
