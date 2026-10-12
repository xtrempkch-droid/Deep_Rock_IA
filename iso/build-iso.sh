#!/usr/bin/env bash
#
# iso/build-iso.sh — gera uma ISO de instalação do ai-cpu-os
# -----------------------------------------------------------------------------
# Pega uma ISO oficial, injeta o projeto ai-cpu-os + a configuração de
# instalação automática e remonta uma ISO nova que instala tudo sozinha.
#
# Dois caminhos suportados (`--distro`):
#   * ubuntu (PADRÃO) → Ubuntu Server live + **autoinstall** (Subiquity).
#     A config vai como `autoinstall.yaml` na RAIZ da ISO (ao lado de `casper/`)
#     e a remontagem usa `xorriso -indev/-outdev -map`, preservando os setores
#     de boot originais byte a byte.
#   * debian (LEGADO, funcional) → Debian netinst + preseed (d-i), com o
#     caminho de extração + remontagem via mkisofs descrito mais abaixo.
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
#   --distro NAME         ubuntu (padrão) | debian
#   --disk DEV            Disco alvo do particionamento (APAGADO). Obrigatório
#                         sem --dry-run, a menos que --allow-any-disk seja usado.
#   --allow-any-disk      Não fixa o disco: o instalador escolhe sozinho.
#   --out PATH            Caminho da ISO de saída (padrão: iso/out/ai-cpu-os-<distro>-<data>.iso)
#   --iso PATH            Usa uma ISO local em vez de baixar.
#   --iso-url URL         URL da ISO (padrão: descobre a versão atual do distro).
#   --sha256 SUM          Checksum esperado (opcional, se --iso for usado).
#   --role NAME           Papel gravado na ISO: auto|inference|builder (padrão: auto).
#   --family NAME         Família gravada na ISO: auto ou um id (padrão: auto).
#   --firstboot-reboot    Reinicia automaticamente ao fim do primeiro boot.
#   --hostname NAME       Hostname do sistema instalado (padrão: <usuario>).
#   --username NAME       Usuário administrativo (padrão: ai-cpu-os).
#   --password-hash HASH  Hash da senha (crypt). Se omitido, gera e mostra um.
#   --locale / --keymap / --timezone / --mirror-host / --mirror-dir
#   --extra-packages "…"  Pacotes extras (separados por espaço).
#   --work-dir DIR        Diretório de trabalho (padrão: iso/work).
#   --keep-work           Não apaga o diretório de trabalho no fim.
#   --dry-run             Mostra tudo o que seria feito, sem alterar nada.
#   --yes                 Não pede confirmação (automação/CI).
#   -h | --help           Esta ajuda.
#
# Requisitos: xorriso, curl, sha256sum, tar.
#   Opcionais: mtools + isolinux (apenas no caminho Debian: boot UEFI dentro de
#   efi.img e boot híbrido via isohdpfx.bin).
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

readonly DEBIAN_CD_BASE_DEFAULT="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd"
# Ubuntu Server live (amd64). O padrão aponta para a série LTS mais recente;
# para outra versão use --iso-url com a URL do diretório de sua escolha.
readonly UBUNTU_CD_BASE_DEFAULT="https://releases.ubuntu.com/24.04"
readonly UBUNTU_ISO_PATTERN='live-server-amd64\.iso$'

# --- configuração (sobrescrita por argumentos) ------------------------------
DISTRO="ubuntu"
DISK=""
ALLOW_ANY_DISK=0
OUT_ISO=""
INPUT_ISO=""
ISO_URL=""
EXPECTED_SHA=""
ROLE="auto"
FAMILY="auto"
FIRSTBOOT_REBOOT="no"
USERNAME="ai-cpu-os"
USER_FULLNAME="ai-cpu-os"
# Nome HOSTNAME NÃO é usado de propósito: o bash já define uma variável com esse
# nome e sobrescrevê-la confunde quem lê o script.
SYS_HOSTNAME=""
PASSWORD_HASH=""
GENERATED_PASSWORD=""
LOCALE="pt_BR.UTF-8"
LANG_CODE="pt"
COUNTRY="BR"
KEYMAP="br"
TIMEZONE="America/Sao_Paulo"
# Espelho do apt apenas no caminho Debian (o Ubuntu fixa archive.ubuntu.com
# no autoinstall.yaml — ver o comentário "Repositório determinístico" lá).
MIRROR_HOST="deb.debian.org"
MIRROR_DIR="/debian"
GRUB_WITH_OTHER_OS="true"
EXTRA_PACKAGES="git curl ca-certificates build-essential pkg-config libopenblas-dev gnupg jq pciutils util-linux openssh-server"
WORK_DIR="${ISO_DIR}/work"
KEEP_WORK=0
DRY_RUN=0
ASSUME_YES=0
CHECK_TEMPLATES=0

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
  --distro NAME         ubuntu (padrão, autoinstall) | debian (preseed).
  --disk DEV            Disco alvo do particionamento (APAGADO).
  --allow-any-disk      Não fixa o disco (o instalador escolhe).
  --out PATH            ISO de saída (padrão: iso/out/ai-cpu-os-<distro>-<data>.iso).
  --iso PATH            Usa uma ISO local em vez de baixar.
  --iso-url URL         URL da ISO (padrão: descobre a versão atual).
  --sha256 SUM          Checksum esperado (com --iso).
  --role NAME           Papel gravado na ISO: auto|inference|builder (padrão: auto).
  --family NAME         Família gravada na ISO: auto ou um id (padrão: auto).
  --firstboot-reboot    Reinicia ao fim do primeiro boot (aplica C-states).
  --hostname NAME       Hostname do sistema instalado (padrão: <usuario>).
  --username NAME       Usuário administrativo (padrão: ai-cpu-os).
  --password-hash HASH  Hash crypt da senha. Se omitido, gera e mostra um.
  --locale / --keymap / --timezone / --mirror-host / --mirror-dir
  --extra-packages "…"  Pacotes extras instalados no alvo.
  --work-dir DIR        Diretório de trabalho (padrão: iso/work).
  --keep-work           Não apaga o diretório de trabalho.
  --check-templates     Autoteste: substitui os templates e valida o YAML gerado
                        (não gera ISO, não precisa de disco nem root).
  --dry-run             Simula tudo, sem alterar nada.
  --yes                 Não pede confirmação.
  -h | --help           Esta ajuda.

Requisitos: xorriso, curl, sha256sum, tar.
  Opcionais (só no caminho Debian): mtools (boot UEFI dentro de efi.img) e
  isolinux (isohdpfx.bin para boot híbrido BIOS+EFI).

⚠️ A ISO gerada APAGA o disco alvo. Boote em VM antes de usar em hardware.
   Ver docs/ISO.md e o Bloco M de docs/VALIDATION.md.
EOF
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
      --hostname)        [[ $# -ge 2 ]] || { log_error "--hostname exige valor"; exit 2; }; SYS_HOSTNAME="$2"; shift 2 ;;
      --username)        [[ $# -ge 2 ]] || { log_error "--username exige valor"; exit 2; }; USERNAME="$2"; shift 2 ;;
      --password-hash)   [[ $# -ge 2 ]] || { log_error "--password-hash exige valor"; exit 2; }; PASSWORD_HASH="$2"; shift 2 ;;
      --locale)          [[ $# -ge 2 ]] || { log_error "--locale exige valor"; exit 2; }; LOCALE="$2"; shift 2 ;;
      --keymap)          [[ $# -ge 2 ]] || { log_error "--keymap exige valor"; exit 2; }; KEYMAP="$2"; shift 2 ;;
      --timezone)        [[ $# -ge 2 ]] || { log_error "--timezone exige valor"; exit 2; }; TIMEZONE="$2"; shift 2 ;;
      --mirror-host)     [[ $# -ge 2 ]] || { log_error "--mirror-host exige valor"; exit 2; }; MIRROR_HOST="$2"; shift 2 ;;
      --mirror-dir)      [[ $# -ge 2 ]] || { log_error "--mirror-dir exige valor"; exit 2; }; MIRROR_DIR="$2"; shift 2 ;;
      --extra-packages)  [[ $# -ge 2 ]] || { log_error "--extra-packages exige valor"; exit 2; }; EXTRA_PACKAGES="$2"; shift 2 ;;
      --work-dir)        [[ $# -ge 2 ]] || { log_error "--work-dir exige valor"; exit 2; }; WORK_DIR="$2"; shift 2 ;;
      --keep-work)       KEEP_WORK=1; shift ;;
      --check-templates) CHECK_TEMPLATES=1; DRY_RUN=1; shift ;;
      --dry-run)         DRY_RUN=1; shift ;;
      --yes)             ASSUME_YES=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  case "$DISTRO" in
    ubuntu|debian) ;;
    *) log_error "Distro inválida: '${DISTRO}' (use ubuntu ou debian)."; exit 2 ;;
  esac

  case "$ROLE" in
    auto|inference|builder) ;;
    *) log_error "Papel inválido: '${ROLE}' (use auto, inference ou builder)."; exit 2 ;;
  esac

  # A justificativa técnica está no comentário do autoinstall.yaml (repositório
  # determinístico). Aqui apenas avisamos para evitar confusão.
  if [[ "$DISTRO" == "ubuntu" && "$MIRROR_HOST" != "deb.debian.org" ]]; then
    log_warn "--mirror-host só tem efeito no caminho Debian; o Ubuntu usa archive.ubuntu.com."
  fi

  if [[ -z "$SYS_HOSTNAME" ]]; then
    SYS_HOSTNAME="$(printf '%s' "$USERNAME" | tr '_' '-')"
  fi

  if [[ -z "$DISK" && $ALLOW_ANY_DISK -eq 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Informe o disco alvo com --disk /dev/xxx (será APAGADO)."
    log_error "Se você entende o risco e quer deixar o instalador escolher, use --allow-any-disk."
    exit 2
  fi

  if [[ -z "$OUT_ISO" ]]; then
    OUT_ISO="${ISO_DIR}/out/ai-cpu-os-${DISTRO}-$(date +%Y%m%d).iso"
  fi
}

# ---------------------------------------------------------------------------
# Dependências
# ---------------------------------------------------------------------------
HAS_MTOOLS=0
HAS_ISOHDPFX=""

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

  # mtools e isohdpfx.bin só são usados no caminho Debian. O Ubuntu preserva os
  # setores de boot originais via `xorriso -indev/-outdev -map`, então NÃO
  # precisa de nenhum dos dois — vale avisar para não assustar quem só quer
  # gerar a ISO Ubuntu.
  if [[ "$DISTRO" == "ubuntu" ]]; then
    log_info "Distro ubuntu: mtools/isolinux não são necessários (setores de boot preservados)."
    return 0
  fi

  command -v mcopy >/dev/null 2>&1 && HAS_MTOOLS=1

  local cand
  for cand in /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/mbr/isohdpfx.bin; do
    if [[ -f "$cand" ]]; then HAS_ISOHDPFX="$cand"; break; fi
  done

  if [[ -z "$HAS_ISOHDPFX" ]]; then
    log_warn "isohdpfx.bin não encontrado: a ISO sairá sem boot híbrido via MBR."
    log_warn "Instale o pacote 'isolinux' para habilitar o boot BIOS+EFI: apt-get install -y isolinux"
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
  local default_base pattern sum_pattern
  if [[ "$DISTRO" == "ubuntu" ]]; then
    default_base="$UBUNTU_CD_BASE_DEFAULT"
    pattern="$UBUNTU_ISO_PATTERN"
    sum_pattern='live-server-amd64\.iso$'
  else
    default_base="$DEBIAN_CD_BASE_DEFAULT"
    pattern='netinst\.iso$'
    sum_pattern='netinst\.iso$'
  fi

  local base_url="${ISO_URL:-$default_base}"
  if [[ -n "$ISO_URL" ]]; then
    # URL completa foi dada; usamos o nome do arquivo e, se possível, o SHA256SUMS.
    base_url="$(dirname "$ISO_URL")"
  fi

  local sums_url="${base_url}/SHA256SUMS"
  local sums_file="${WORK_DIR}/cache/SHA256SUMS"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] baixaria ${sums_url} e escolheria a entrada que casa com /${pattern}/"
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
    local want; want="$(basename "$ISO_URL")"
    entry="$(awk -v w="$want" '$2 ~ w"$" {print $1" "$2; exit}' "$sums_file")"
  else
    entry="$(awk -v p="$sum_pattern" '$2 ~ p {print $1" "$2; exit}' "$sums_file")"
  fi

  if [[ -z "$entry" ]]; then
    log_error "Não encontrei um arquivo que casa com /${sum_pattern}/ em ${sums_url}"
    exit 1
  fi

  EXPECTED_SHA="${entry%% *}"
  local filename="${entry##* }"
  # Alguns SHA256SUMS vêm com prefixo ./
  filename="${filename#./}"
  log_info "Alvo: ${filename} (sha256 ${EXPECTED_SHA:0:16}…)"

  local dest="${WORK_DIR}/cache/${filename}"
  if [[ -f "$dest" ]] && verify_sha_quiet "$dest" "$EXPECTED_SHA"; then
    log_info "ISO já está no cache e confere com o SHA256SUMS (reutilizando)."
  else
    log_info "Baixando ${base_url}/${filename} (≈ 700 MB no Debian, ≈ 2.6 GB no Ubuntu)…"
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
# Layout: extração (Debian) ou preparação do stage (Ubuntu)
# ---------------------------------------------------------------------------
EXTRACT_DIR=""
ISO_ROOT=""
UBUNTU_STAGE=""
UBUNTU_GRUB_BIOS=""
UBUNTU_GRUB_EFI=""

# Debian: extrai a ISO inteira e edita a árvore no lugar (isolinux + efi.img).
extract_iso_debian() {
  section "Extração (Debian)"
  EXTRACT_DIR="${WORK_DIR}/extract"
  ISO_ROOT="${EXTRACT_DIR}"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] xorriso -osirrox on -indev ${ISO_PATH} -extract / ${EXTRACT_DIR}"
    return 0
  fi

  rm -rf "$EXTRACT_DIR"
  mkdir -p "$EXTRACT_DIR"

  # Permite sobrescrever arquivos ao extrair (o xorriso é conservador por padrão).
  run "Extraindo a ISO" xorriso -osirrox on -overwrite on -indev "$ISO_PATH" -extract / "$EXTRACT_DIR"
  # Alguns arquivos vêm somente-leitura e atrapalham a edição.
  chmod -R u+w "$EXTRACT_DIR" 2>/dev/null || true

  if [[ ! -d "${ISO_ROOT}/isolinux" ]]; then
    log_error "Layout inesperado: ${ISO_ROOT}/isolinux não existe."
    log_error "Para Ubuntu, use --distro ubuntu (autoinstall). Ver docs/ISO.md."
    exit 1
  fi
  log_ok "ISO extraída em ${EXTRACT_DIR}"
}

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
    log_error "Para Debian netinst, use --distro debian. Ver docs/ISO.md."
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
  # Debian: entra na árvore extraída. Ubuntu: entra no stage (vai para a ISO via -map).
  local base
  if [[ "$DISTRO" == "ubuntu" ]]; then
    base="${UBUNTU_STAGE}"
  else
    base="${ISO_ROOT}"
  fi
  local dest="${base}/ai-cpu-os"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${REPO_ROOT} → ${dest} (sem .git, sem iso/work, sem iso/out, sem *.iso)"
    return 0
  fi

  mkdir -p "$dest"
  tar -C "$REPO_ROOT" -cf - \
      --exclude=./.git \
      --exclude=./iso/work \
      --exclude=./iso/out \
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

# Substitui tokens @@NOME@@ nos templates (preseed e autoinstall).
subst_template() {
  local src="$1" dst="$2"
  local hash_esc store_esc
  hash_esc="$(_sed_repl "$PASSWORD_HASH")"
  store_esc="$(_sed_repl "$(storage_layout_line)")"
  sed \
    -e "s|@@DISTRO@@|${DISTRO}|g" \
    -e "s|@@ROLE@@|${ROLE}|g" \
    -e "s|@@FAMILY@@|${FAMILY}|g" \
    -e "s|@@FIRSTBOOT_REBOOT@@|${FIRSTBOOT_REBOOT}|g" \
    -e "s|@@ISO_BUILD@@|${ISO_BUILD_ID}|g" \
    -e "s|@@USERNAME@@|${USERNAME}|g" \
    -e "s|@@USER_FULLNAME@@|${USER_FULLNAME}|g" \
    -e "s|@@HOSTNAME@@|${SYS_HOSTNAME}|g" \
    -e "s|@@PASSWORD_HASH@@|${hash_esc}|g" \
    -e "s|@@LOCALE@@|${LOCALE}|g" \
    -e "s|@@LANG@@|${LANG_CODE}|g" \
    -e "s|@@COUNTRY@@|${COUNTRY}|g" \
    -e "s|@@KEYMAP@@|${KEYMAP}|g" \
    -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
    -e "s|@@MIRROR_HOST@@|${MIRROR_HOST}|g" \
    -e "s|@@MIRROR_DIR@@|${MIRROR_DIR}|g" \
    -e "s|@@GRUB_WITH_OTHER_OS@@|${GRUB_WITH_OTHER_OS}|g" \
    -e "s|@@EXTRA_PACKAGES@@|${EXTRA_PACKAGES}|g" \
    -e "s|@@STORAGE_LAYOUT@@|${store_esc}|g" \
    -e "s|@@PARTMAN_DISK@@|${PARTMAN_DISK_LINE}|g" \
    "$src" > "$dst"
}

# Grava os templates COMUNS aos dois distros (o late-command e o serviço de
# primeiro boot são compartilhados — eles rodam no sistema instalado).
inject_common_templates() {
  local dest="$1"
  mkdir -p "$dest"
  subst_template "${ISO_DIR}/preseed/late-command.sh"     "${dest}/late-command.sh"
  subst_template "${ISO_DIR}/preseed/firstboot.sh"        "${dest}/firstboot.sh"
  cp "${ISO_DIR}/preseed/ai-cpu-os-firstboot.service"     "${dest}/ai-cpu-os-firstboot.service"
  chmod 0755 "${dest}/late-command.sh" "${dest}/firstboot.sh"
  chmod 0644 "${dest}/ai-cpu-os-firstboot.service"
}

# Rede de segurança: se algum marcador REAL sobrou, a instalação não funciona.
# (Verificamos apenas os nomes esperados — comentários podem conter o formato,
#  então um grep genérico por arrobas daria falso positivo.)
# Retorna 1 (não aborta) para que o autoteste possa acumular falhas.
check_no_leftover_tokens() {
  local -a required_tokens=(
    DISTRO ROLE FAMILY FIRSTBOOT_REBOOT ISO_BUILD USERNAME USER_FULLNAME HOSTNAME PASSWORD_HASH
    LOCALE KEYMAP TIMEZONE EXTRA_PACKAGES PACKAGES_BLOCK STORAGE_LAYOUT
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
  section "Configuração de instalação (${DISTRO})"

  if [[ "$DISTRO" == "ubuntu" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] gravaria ${UBUNTU_STAGE}/autoinstall.yaml e ${UBUNTU_STAGE}/preseed/*"
      log_info "[dry-run] disco: ${DISK:-<não fixado>} · papel: ${ROLE} · família: ${FAMILY} · usuário: ${USERNAME}"
      return 0
    fi
    subst_template "${ISO_DIR}/autoinstall/autoinstall.yaml" "${UBUNTU_STAGE}/autoinstall.yaml"
    # A lista de pacotes vira uma sequência em bloco do YAML (ver a função).
    expand_packages_block "${UBUNTU_STAGE}/autoinstall.yaml"
    chmod 0644 "${UBUNTU_STAGE}/autoinstall.yaml"
    inject_common_templates "${UBUNTU_STAGE}/preseed"
    check_no_leftover_tokens "${UBUNTU_STAGE}/autoinstall.yaml" \
                            "${UBUNTU_STAGE}/preseed/late-command.sh" \
                            "${UBUNTU_STAGE}/preseed/firstboot.sh" || exit 1
    log_ok "autoinstall.yaml e preseed/* gravados no stage (marcadores OK)."
    log_info "Storage: $(storage_layout_line)"
    return 0
  fi

  # --- Debian -------------------------------------------------------------
  local dest="${ISO_ROOT}/preseed"

  # Linha do partman: se o disco não foi informado, comentamos a linha (o
  # instalador usa o primeiro disco) — mas isso é explicitamente consentido.
  if [[ -n "$DISK" ]]; then
    PARTMAN_DISK_LINE="d-i partman-auto/disk string ${DISK}"
  else
    PARTMAN_DISK_LINE="# --allow-any-disk: partman usará o primeiro disco disponível"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] gravaria ${dest}/{ai-cpu-os.cfg,late-command.sh,firstboot.sh,ai-cpu-os-firstboot.service}"
    log_info "[dry-run] disco: ${DISK:-<não fixado>} · papel: ${ROLE} · família: ${FAMILY} · usuário: ${USERNAME}"
    return 0
  fi

  mkdir -p "$dest"
  subst_template "${ISO_DIR}/preseed/ai-cpu-os.cfg" "${dest}/ai-cpu-os.cfg"
  chmod 0644 "${dest}/ai-cpu-os.cfg"
  inject_common_templates "$dest"
  check_no_leftover_tokens "${dest}/ai-cpu-os.cfg" "${dest}/late-command.sh" "${dest}/firstboot.sh" || exit 1

  log_ok "Preseed gravado em ${dest} (todos os marcadores substituídos)."
}

patch_isolinux() {
  section "Boot BIOS (Debian/isolinux)"
  local cfg="${ISO_ROOT}/isolinux/isolinux.cfg"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] descobriria install.*/vmlinuz e initrd.gz"
    log_info "[dry-run] ajustaria default/timeout/prompt em isolinux.cfg e acrescentaria:"
    log_info "         label ai-cpu-os-auto → preseed/file=/cdrom/preseed/ai-cpu-os.cfg"
    return 0
  fi

  if [[ ! -f "$cfg" ]]; then
    log_warn "${cfg} não encontrado; pulando o patch do boot BIOS."
    return 0
  fi

  # Descobrir o kernel/initrd do instalador.
  local rel; rel="$(cd "$ISO_ROOT" && ls -d install.* 2>/dev/null | head -1 || true)"
  if [[ -z "$rel" ]]; then
    log_error "Não encontrei o diretório install.* (kernel do instalador)."
    exit 1
  fi
  KERNEL_PATH="/${rel}/vmlinuz"
  if [[ -f "${ISO_ROOT}/${rel}/initrd.gz" ]]; then
    INITRD_PATH="/${rel}/initrd.gz"
  elif [[ -f "${ISO_ROOT}/${rel}/gtk/initrd.gz" ]]; then
    INITRD_PATH="/${rel}/gtk/initrd.gz"
  else
    log_error "Não encontrei o initrd.gz do instalador em ${rel}/."
    exit 1
  fi
  log_info "Kernel: ${KERNEL_PATH} · initrd: ${INITRD_PATH}"

  cp -a "$cfg" "${cfg}.orig"
  sed -i -E 's/^[[:space:]]*default[[:space:]].*/default ai-cpu-os-auto/' "$cfg"
  sed -i -E 's/^[[:space:]]*timeout[[:space:]].*/timeout 100/'            "$cfg"
  sed -i -E 's/^[[:space:]]*prompt[[:space:]].*/prompt 1/'               "$cfg"

  cat >> "$cfg" <<EOF

# ---------------------------------------------------------------------------
# ai-cpu-os: entrada de boot automática (inserida por iso/build-iso.sh)
# ---------------------------------------------------------------------------
label ai-cpu-os-auto
 menu label ^Instalar ai-cpu-os (automatico${DISK:+, APAGA ${DISK}})
 kernel ${KERNEL_PATH}
 append vga=788 initrd=${INITRD_PATH} auto=true priority=critical preseed/file=/cdrom/preseed/ai-cpu-os.cfg --- quiet
EOF
  log_ok "Boot BIOS configurado (default ai-cpu-os-auto, timeout 10s)."
}

patch_efi_debian() {
  section "Boot UEFI (Debian)"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] procuraria EFI/*/grub.cfg (ou grub.cfg dentro de efi.img, via mtools)"
    log_info "[dry-run] e acrescentaria a menuentry 'ai-cpu-os-auto' como padrão"
    return 0
  fi

  # Caso 1: grub.cfg solto na ISO (mais simples).
  local direct=""
  local cand
  for cand in "EFI/boot/grub.cfg" "EFI/debian/grub.cfg" "boot/grub/grub.cfg"; do
    if [[ -f "${ISO_ROOT}/${cand}" ]]; then direct="$cand"; break; fi
  done

  if [[ -n "$direct" ]]; then
    log_info "Encontrei ${direct} na ISO; acrescentando a entrada automática."
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] acrescentaria a menuentry 'ai-cpu-os-auto' em ${direct}"
      return 0
    fi
    cp -a "${ISO_ROOT}/${direct}" "${ISO_ROOT}/${direct}.orig"
    # Acrescentamos no FIM para que `set default` tenha efeito (o arquivo é
    # interpretado sequencialmente pelo GRUB).
    cat >> "${ISO_ROOT}/${direct}" <<EOF

# ai-cpu-os: entrada automática (iso/build-iso.sh)
set timeout=10
set default="ai-cpu-os-auto"
menuentry "Instalar ai-cpu-os (automatico)" {
  linux  ${KERNEL_PATH} auto=true priority=critical preseed/file=/cdrom/preseed/ai-cpu-os.cfg --- quiet
  initrd ${INITRD_PATH}
}
EOF
    log_ok "Boot UEFI configurado em ${direct}."
    return 0
  fi

  # Caso 2: grub.cfg dentro de uma imagem FAT (efi.img).
  local img
  img="$(cd "$ISO_ROOT" && find . -type f -name 'efi.img' 2>/dev/null | head -1 || true)"
  if [[ -z "$img" ]]; then
    log_warn "Não encontrei efi.img; a ISO pode não bootar por UEFI."
    log_warn "O boot BIOS (isolinux) está configurado e é o caminho principal."
    return 0
  fi
  img="${img#./}"

  if [[ $HAS_MTOOLS -eq 0 ]]; then
    log_warn "UEFI: ${img} existe, mas 'mtools' não está instalado."
    log_warn "Sem mtools, o boot UEFI cai no menu padrão do Debian (instalação NÃO automática)."
    log_warn "Instale 'mtools' para habilitar o patch do UEFI: apt-get install -y mtools"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] procuraria grub.cfg dentro de ${img} (mtools) e acrescentaria a entrada automática"
    return 0
  fi

  # Descobrir o grub.cfg dentro da imagem FAT.
  local inside
  inside="$(mdir -i "${ISO_ROOT}/${img}" ::/ -b 2>/dev/null | awk '{print $NF, $1}' \
            | grep -i 'grub\.cfg$' | head -1 | awk '{print $2}' || true)"
  if [[ -z "$inside" ]]; then
    log_warn "Não encontrei grub.cfg dentro de ${img}; boot UEFI sem automação."
    return 0
  fi

  local tmp; tmp="$(mktemp)"
  if ! mcopy -i "${ISO_ROOT}/${img}" "::${inside}" "$tmp" 2>/dev/null; then
    log_warn "Falha ao extrair ${inside} de ${img}; boot UEFI sem automação."
    rm -f "$tmp"
    return 0
  fi

  cat >> "$tmp" <<EOF

# ai-cpu-os: entrada automática (iso/build-iso.sh)
set timeout=10
set default="ai-cpu-os-auto"
menuentry "Instalar ai-cpu-os (automatico)" {
  linux  ${KERNEL_PATH} auto=true priority=critical preseed/file=/cdrom/preseed/ai-cpu-os.cfg --- quiet
  initrd ${INITRD_PATH}
}
EOF

  if mcopy -o -i "${ISO_ROOT}/${img}" "$tmp" "::${inside}" 2>/dev/null; then
    log_ok "Boot UEFI configurado dentro de ${img} (${inside})."
  else
    log_warn "Falha ao gravar ${inside} em ${img}; boot UEFI sem automação."
  fi
  rm -f "$tmp"
}

regenerate_md5sums() {
  local f="${ISO_ROOT}/md5sum.txt"
  if [[ "$DISTRO" == "ubuntu" ]]; then
    # No Ubuntu a árvore da ISO não é extraída (remontamos via -indev/-outdev),
    # então não há como regenerar de forma barata. O `md5sum.txt` original fica
    # obsoleto e é REMOVIDO na remontagem (ver repack_iso_ubuntu).
    log_info "Ubuntu: md5sum.txt será removido na remontagem (não é usado pelo Subiquity)."
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] regeneraria md5sum.txt (todos os arquivos, exceto ele mesmo)"
    return 0
  fi
  if [[ ! -f "$f" ]]; then
    log_warn "md5sum.txt não encontrado; nada a regenerar."
    return 0
  fi
  log_info "Regenerando md5sum.txt (o instalador verifica a integridade da mídia)…"
  ( cd "$ISO_ROOT" \
    && find . -type f ! -name md5sum.txt -print0 \
       | LC_ALL=C sort -z \
       | xargs -0 md5sum > /tmp/ai-cpu-os-md5sum.txt \
    && mv /tmp/ai-cpu-os-md5sum.txt md5sum.txt )
  log_ok "md5sum.txt regenerado ($(wc -l < "$f") entradas)."
}

# ---------------------------------------------------------------------------
# Boot do Ubuntu (GRUB): não há isolinux. Descobrimos o kernel/initrd do
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

# Acrescenta timeout/default + a menuentry automática ao fim de um grub.cfg.
# `autoinstall` é o parâmetro de kernel que liga o modo não interativo; o
# `autoinstall.yaml` é achado sozinho na raiz da mídia (ver o cabeçalho do
# template em iso/autoinstall/autoinstall.yaml).
append_grub_ai_entry() {
  local f="$1"
  cat >> "$f" <<EOF

# ---------------------------------------------------------------------------
# ai-cpu-os: entrada de boot automática (inserida por iso/build-iso.sh)
# ---------------------------------------------------------------------------
set timeout=10
set default="ai-cpu-os-auto"
menuentry "Instalar ai-cpu-os (automatico${DISK:+, APAGA ${DISK}})" {
    set gfxpayload=keep
    linux   ${KERNEL_PATH} autoinstall quiet ---
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
  # volume id original é arriscado: o do Debian tem espaços e o do Ubuntu tem
  # minúsculas e pontos, que o xorriso pode recusar no `-V`.
  printf '%s' "AI_CPU_OS_${DISTRO}_${ROLE}" \
    | tr '[:lower:]' '[:upper:]' \
    | tr -c 'A-Z0-9_' '_' \
    | tr -s '_' \
    | cut -c1-32
}

repack_iso() {
  section "Remontagem da ISO"
  mkdir -p "$(dirname "$OUT_ISO")"

  if [[ "$DISTRO" == "ubuntu" ]]; then
    repack_iso_ubuntu
    return 0
  fi

  local efi_img=""
  if [[ $DRY_RUN -eq 0 ]]; then
    efi_img="$(cd "$ISO_ROOT" 2>/dev/null && find . -type f -name 'efi.img' 2>/dev/null | head -1 | sed 's|^\./||' || true)"
  fi

  local -a cmd=(
    -as mkisofs
    -r -J -joliet-long -l -iso-level 3
    -V "$VOLUME_ID"
    -c isolinux/boot.cat
    -b isolinux/isolinux.bin
      -no-emul-boot -boot-load-size 4 -boot-info-table
  )
  if [[ -n "$HAS_ISOHDPFX" ]]; then
    cmd+=(-isohybrid-mbr "$HAS_ISOHDPFX")
  fi
  if [[ -n "$efi_img" ]]; then
    cmd+=(-eltorito-alt-boot -e "$efi_img" -no-emul-boot -isohybrid-gpt-basdat)
    log_info "Boot UEFI (El Torito): ${efi_img}"
  fi
  cmd+=(-o "$OUT_ISO" "$ISO_ROOT")

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] xorriso ${cmd[*]}"
    return 0
  fi

  run "Gerando a ISO" xorriso "${cmd[@]}"
  log_ok "ISO gerada: ${OUT_ISO}"
}

# Ubuntu: remonta com `-indev/-outdev -map`, ou seja, PARTINDO da ISO oficial e
# apenas sobrepondo o que mudou. É a diferença de fundo em relação ao caminho
# Debian (que extrai a árvore e a reconstrói com mkisofs): assim os setores de
# boot do Ubuntu — El Torito BIOS, imagem EFI e MBR híbrido — ficam
# byte a byte iguais aos da ISO oficial, sem depender de mtools nem de
# isohdpfx.bin.
repack_iso_ubuntu() {
  local -a args=(
    -indev "$ISO_PATH"
    -outdev "$OUT_ISO"
    -boot_image any keep
    -volid "$VOLUME_ID"
    -map "${UBUNTU_STAGE}/ai-cpu-os"        /ai-cpu-os
    -map "${UBUNTU_STAGE}/preseed"          /preseed
    -map "${UBUNTU_STAGE}/autoinstall.yaml" /autoinstall.yaml
    -map "$UBUNTU_GRUB_BIOS"                /boot/grub/grub.cfg
  )

  if [[ -n "$UBUNTU_GRUB_EFI" ]]; then
    args+=(-map "$UBUNTU_GRUB_EFI" /EFI/boot/grub.cfg)
  fi

  # O md5sum.txt original descreve a mídia ANTES das nossas alterações. O
  # Subiquity não o usa no autoinstall, mas um arquivo obsoleto confunde quem
  # for inspecionar a ISO. Removemos apenas se ele existir (senão o xorriso
  # reclama de um caminho inexistente).
  if [[ $DRY_RUN -eq 0 ]] \
     && [[ -n "$(xorriso -indev "$ISO_PATH" -find /md5sum.txt -type f 2>/dev/null || true)" ]]; then
    args+=(-rm /md5sum.txt)
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
  listing="$(xorriso -indev "$OUT_ISO" -find /preseed -type f -exec echo 2>/dev/null || true)"
  if [[ -n "$listing" ]]; then
    log_ok "Conteúdo de /preseed na ISO:"
    printf '    | %s\n' $listing
  else
    log_warn "Não consegui listar /preseed na ISO gerada (verifique manualmente)."
  fi

  if [[ -n "$(xorriso -indev "$OUT_ISO" -find /ai-cpu-os/build.sh -type f 2>/dev/null || true)" ]]; then
    log_ok "Projeto presente em /ai-cpu-os na ISO."
  else
    log_warn "Não confirmei /ai-cpu-os na ISO gerada."
  fi

  # Configuração de instalação: cada distro tem a sua, e é ELA que faz a
  # instalação ser automática — então vale confirmar que chegou na ISO.
  if [[ "$DISTRO" == "ubuntu" ]]; then
    if [[ -n "$(xorriso -indev "$OUT_ISO" -find /autoinstall.yaml -type f 2>/dev/null || true)" ]]; then
      log_ok "autoinstall.yaml presente na raiz da ISO (é achado ao lado de casper/)."
    else
      log_error "autoinstall.yaml AUSENTE: a instalação não seria automática."
      exit 1
    fi
  else
    if [[ -n "$(xorriso -indev "$OUT_ISO" -find /preseed/ai-cpu-os.cfg -type f 2>/dev/null || true)" ]]; then
      log_ok "Preseed presente em /preseed/ai-cpu-os.cfg."
    else
      log_error "Preseed AUSENTE: a instalação não seria automática."
      exit 1
    fi
  fi

  # O menu de boot precisa ter a nossa entrada padrão.
  if [[ "$DISTRO" == "ubuntu" ]]; then
    local grub_txt
    grub_txt="$(xorriso -osirrox on -indev "$OUT_ISO" -extract /boot/grub/grub.cfg /dev/stdout 2>/dev/null || true)"
    if [[ "$grub_txt" == *ai-cpu-os-auto* ]]; then
      log_ok "Menu do GRUB com a entrada automática 'ai-cpu-os-auto'."
    else
      log_warn "Não confirmei a entrada 'ai-cpu-os-auto' no menu do GRUB."
    fi
  else
    if grep -q 'ai-cpu-os-auto' "${ISO_ROOT}/isolinux/isolinux.cfg" 2>/dev/null; then
      log_ok "Menu do isolinux com a entrada automática 'ai-cpu-os-auto'."
    else
      log_warn "Não confirmei a entrada 'ai-cpu-os-auto' no isolinux.cfg."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Autoteste dos templates (usado pelo CI e pelo `make iso-yaml`)
# ---------------------------------------------------------------------------
# Substitui os templates com valores de exemplo, confere que nenhum marcador
# sobrou, valida a sintaxe dos scripts gerados e (se o yamllint existir) o YAML
# do autoinstall. Cobre os DOIS layouts de storage (com e sem --disk).
#
# Por que isto existe: o template do autoinstall NÃO é YAML válido enquanto tem
# `@@STORAGE_LAYOUT@@` (o `@` é indicador reservado do YAML), então o yamllint
# não consegue validá-lo diretamente — só o arquivo SUBSTITUÍDO é YAML de
# verdade. Este autoteste é o que fecha essa lacuna.
check_templates() {
  section "Autoteste dos templates"
  local tmp rc=0
  tmp="$(mktemp -d)"

  PASSWORD_HASH="${PASSWORD_HASH:-\$6\$EXEMPLO\$autoteste}"

  local variant disk dir
  for variant in com-disco sem-disco; do
    if [[ "$variant" == "com-disco" ]]; then disk="/dev/nvme0n1"; else disk=""; fi
    DISK="$disk"
    dir="${tmp}/${variant}"
    mkdir -p "$dir"

    subst_template "${ISO_DIR}/autoinstall/autoinstall.yaml" "${dir}/autoinstall.yaml"
    expand_packages_block "${dir}/autoinstall.yaml"
    subst_template "${ISO_DIR}/preseed/late-command.sh"       "${dir}/late-command.sh"
    subst_template "${ISO_DIR}/preseed/firstboot.sh"          "${dir}/firstboot.sh"
    subst_template "${ISO_DIR}/preseed/ai-cpu-os.cfg"         "${dir}/ai-cpu-os.cfg"

    log_info "variante '${variant}': storage = $(storage_layout_line)"
    log_info "              packages =${EXTRA_PACKAGES:+ }${EXTRA_PACKAGES}"

    if check_no_leftover_tokens "${dir}/autoinstall.yaml" "${dir}/late-command.sh" \
                                "${dir}/firstboot.sh" "${dir}/ai-cpu-os.cfg"; then
      log_ok "  marcadores: todos substituídos"
    else
      rc=1
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

    if command -v yamllint >/dev/null 2>&1; then
      if yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/autoinstall.yaml" >/dev/null 2>&1; then
        log_ok "  autoinstall.yaml: YAML válido"
      else
        log_error "  autoinstall.yaml: YAML inválido"
        yamllint -c "${REPO_ROOT}/.yamllint.yml" "${dir}/autoinstall.yaml" || true
        rc=1
      fi
    else
      log_warn "  yamllint ausente: o YAML do autoinstall NÃO foi validado."
    fi
  done

  DISK=""
  rm -rf "$tmp" 2>/dev/null || true

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
PARTMAN_DISK_LINE=""

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
    exit $?
  fi

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_warn "Sem root: a extração/remontagem costuma funcionar, mas mtools pode reclamar."
  fi

  check_deps
  resolve_password
  acquire_iso

  # A ordem importa: o layout (extração Debian / stage Ubuntu) precisa existir
  # antes de injetar o projeto, e o patch de boot precisa do kernel/initrd que
  # só é conhecido depois do stage/extração.
  if [[ "$DISTRO" == "ubuntu" ]]; then
    prepare_ubuntu
    inject_project
    inject_templates
    patch_boot_ubuntu
  else
    extract_iso_debian
    inject_project
    inject_templates
    # Kernel/initrd são descobertos no patch do isolinux; rodamos primeiro.
    patch_isolinux
    patch_efi_debian
    regenerate_md5sums
  fi

  VOLUME_ID="$(detect_volume_id)"
  log_info "Volume ID da ISO: '${VOLUME_ID}'"

  repack_iso
  verify_output

  section "Resumo"
  log_ok "ISO: ${OUT_ISO}"
  log_info "Distro base: ${DISTRO}"
  log_info "Papel gravado: ${ROLE} (auto = detecta o hardware no primeiro boot)"
  log_info "Família gravada: ${FAMILY} (auto = detecta o hardware no primeiro boot)"
  log_info "Usuário: ${USERNAME} (sudo) · root bloqueado"
  if [[ -n "$GENERATED_PASSWORD" ]]; then
    log_warn "SENHA GERADA: ${GENERATED_PASSWORD} — anote agora, não é recuperável daqui."
  fi
  if [[ -n "$DISK" ]]; then
    log_warn "Partição automática apaga: ${DISK}"
  else
    log_warn "Disco não fixado: o instalador usará o primeiro disco disponível."
  fi
  log_info "Testar em VM: qemu-system-x86_64 -m 4096 -enable-kvm -cdrom '${OUT_ISO}' -boot d"
  log_info "No sistema instalado, o tuning é aplicado no primeiro boot:"
  log_info "    systemctl status ai-cpu-os-firstboot && cat /var/log/ai-cpu-os-firstboot.log"

  if [[ $KEEP_WORK -eq 0 && $DRY_RUN -eq 0 ]]; then
    log_info "Removendo o diretório de trabalho (${WORK_DIR}); use --keep-work para mantê-lo."
    rm -rf "$WORK_DIR" 2>/dev/null || log_warn "Não consegui remover ${WORK_DIR}."
  fi
}

# Permite `source iso/build-iso.sh` para carregar as funções sem executar nada
# (útil para testar a substituição de templates isoladamente — é assim que o
# CI exercita o autoinstall.yaml). Mesmo padrão de families/resolve.sh.
if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
