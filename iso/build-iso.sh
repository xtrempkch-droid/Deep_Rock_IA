#!/usr/bin/env bash
#
# iso/build-iso.sh — gera uma ISO de instalação do ai-cpu-os
# -----------------------------------------------------------------------------
# Pega uma ISO oficial **Debian netinst**, injeta o projeto ai-cpu-os + um
# arquivo de preseed e remonta uma ISO nova que instala tudo automaticamente.
#
# A ISO gerada:
#   * instala um Debian mínimo, não interativo (preseed);
#   * copia o projeto para /opt/ai-cpu-os no sistema instalado;
#   * agenda a aplicação do tuning/perfil para o PRIMEIRO BOOT (no hardware
#     real), via `ai-cpu-os-firstboot.service`.
#
# Uso:
#   sudo bash iso/build-iso.sh --disk /dev/nvme0n1 [opções]
#
# Opções:
#   --disk DEV            Disco alvo do particionamento (APAGADO). Obrigatório
#                         sem --dry-run, a menos que --allow-any-disk seja usado.
#   --allow-any-disk      Não fixa o disco: o instalador usa o "primeiro" disco.
#   --out PATH            Caminho da ISO de saída (padrão: iso/out/ai-cpu-os-<data>.iso)
#   --iso PATH            Usa uma ISO local em vez de baixar.
#   --iso-url URL         URL da ISO (padrão: descobre a netinst atual do Debian).
#   --sha256 SUM          Checksum esperado (opcional, se --iso for usado).
#   --profile NAME        Perfil gravado na ISO: auto|xeon|ryzen (padrão: auto).
#   --firstboot-reboot    Reinicia automaticamente ao fim do primeiro boot.
#   --username NAME       Usuário administrativo (padrão: ai-cpu-os).
#   --password-hash HASH  Hash da senha (crypt). Se omitido, gera e mostra um.
#   --locale / --keymap / --timezone / --mirror-host / --mirror-dir
#   --extra-packages "…"  Pacotes extras (pkgsel/include).
#   --work-dir DIR        Diretório de trabalho (padrão: iso/work).
#   --keep-work           Não apaga o diretório de trabalho no fim.
#   --dry-run             Mostra tudo o que seria feito, sem alterar nada.
#   --yes                 Não pede confirmação (automação/CI).
#   -h | --help           Esta ajuda.
#
# Requisitos: xorriso, curl, sha256sum. Opcionais: mtools (patch de EFI),
#             pacote isolinux (isohdpfx.bin para boot híbrido BIOS+EFI).
#
# ⚠️ Só é suportada a ISO **Debian netinst** (layout isolinux + EFI). O
#    suporte a Ubuntu (autoinstall/Subiquity) está planejado — ver docs/ISO.md.
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

# --- configuração (sobrescrita por argumentos) ------------------------------
DISK=""
ALLOW_ANY_DISK=0
OUT_ISO=""
INPUT_ISO=""
ISO_URL=""
EXPECTED_SHA=""
PROFILE="auto"
FIRSTBOOT_REBOOT="no"
USERNAME="ai-cpu-os"
USER_FULLNAME="ai-cpu-os"
PASSWORD_HASH=""
GENERATED_PASSWORD=""
LOCALE="pt_BR.UTF-8"
LANG_CODE="pt"
COUNTRY="BR"
KEYMAP="br"
TIMEZONE="America/Sao_Paulo"
MIRROR_HOST="deb.debian.org"
MIRROR_DIR="/debian"
GRUB_WITH_OTHER_OS="true"
EXTRA_PACKAGES="git curl ca-certificates build-essential pkg-config libopenblas-dev gnupg jq pciutils util-linux openssh-server"
WORK_DIR="${ISO_DIR}/work"
KEEP_WORK=0
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
build-iso.sh — gera uma ISO de instalação do ai-cpu-os (Debian netinst)

Uso:
  sudo bash iso/build-iso.sh --disk /dev/nvme0n1 [opções]

Opções principais:
  --disk DEV            Disco alvo do particionamento (APAGADO).
  --allow-any-disk      Não fixa o disco (o instalador usa o primeiro).
  --out PATH            ISO de saída (padrão: iso/out/ai-cpu-os-<data>.iso).
  --iso PATH            Usa uma ISO local em vez de baixar.
  --iso-url URL         URL da ISO (padrão: descobre a netinst atual).
  --sha256 SUM          Checksum esperado (com --iso).
  --profile NAME        Perfil gravado na ISO: auto|xeon|ryzen (padrão: auto).
  --firstboot-reboot    Reinicia ao fim do primeiro boot (aplica C-states).
  --username NAME       Usuário administrativo (padrão: ai-cpu-os).
  --password-hash HASH  Hash crypt da senha. Se omitido, gera e mostra um.
  --locale / --keymap / --timezone / --mirror-host / --mirror-dir
  --extra-packages "…"  Pacotes extras instalados no alvo.
  --work-dir DIR        Diretório de trabalho (padrão: iso/work).
  --keep-work           Não apaga o diretório de trabalho.
  --dry-run             Simula tudo, sem alterar nada.
  --yes                 Não pede confirmação.
  -h | --help           Esta ajuda.

Requisitos: xorriso, curl, sha256sum. Opcionais: mtools (boot UEFI),
            pacote isolinux (isohdpfx.bin para boot híbrido BIOS+EFI).

⚠️ Só a ISO Debian netinst é suportada. Ubuntu (autoinstall) está planejado —
   ver docs/ISO.md.
EOF
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)            [[ $# -ge 2 ]] || { log_error "--disk exige valor"; exit 2; }; DISK="$2"; shift 2 ;;
      --allow-any-disk)  ALLOW_ANY_DISK=1; shift ;;
      --out)             [[ $# -ge 2 ]] || { log_error "--out exige valor"; exit 2; }; OUT_ISO="$2"; shift 2 ;;
      --iso)             [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; INPUT_ISO="$2"; shift 2 ;;
      --iso-url)         [[ $# -ge 2 ]] || { log_error "--iso-url exige valor"; exit 2; }; ISO_URL="$2"; shift 2 ;;
      --sha256)          [[ $# -ge 2 ]] || { log_error "--sha256 exige valor"; exit 2; }; EXPECTED_SHA="$2"; shift 2 ;;
      --profile)         [[ $# -ge 2 ]] || { log_error "--profile exige valor"; exit 2; }; PROFILE="$2"; shift 2 ;;
      --firstboot-reboot) FIRSTBOOT_REBOOT="yes"; shift ;;
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
      --dry-run)         DRY_RUN=1; shift ;;
      --yes)             ASSUME_YES=1; shift ;;
      -h|--help)         usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  case "$PROFILE" in
    auto|xeon|ryzen) ;;
    *) log_error "Perfil inválido: '${PROFILE}' (use auto, xeon ou ryzen)."; exit 2 ;;
  esac

  if [[ -z "$DISK" && $ALLOW_ANY_DISK -eq 0 && $DRY_RUN -eq 0 ]]; then
    log_error "Informe o disco alvo com --disk /dev/xxx (será APAGADO)."
    log_error "Se você entende o risco e quer deixar o instalador escolher, use --allow-any-disk."
    exit 2
  fi

  if [[ -z "$OUT_ISO" ]]; then
    OUT_ISO="${ISO_DIR}/out/ai-cpu-os-$(date +%Y%m%d).iso"
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

  # Descobrir a netinst atual e o checksum oficial, para não confiar em URL fixa.
  local base_url="${ISO_URL:-$DEBIAN_CD_BASE_DEFAULT}"
  if [[ -n "$ISO_URL" ]]; then
    # URL completa foi dada; usamos o nome do arquivo e, se possível, o SHA256SUMS.
    base_url="$(dirname "$ISO_URL")"
  fi

  local sums_url="${base_url}/SHA256SUMS"
  local sums_file="${WORK_DIR}/cache/SHA256SUMS"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] baixaria ${sums_url} e escolheria a entrada *netinst.iso"
    ISO_PATH="${WORK_DIR}/cache/debian-netinst.iso"
    EXPECTED_SHA="(do SHA256SUMS oficial)"
    return 0
  fi

  log_info "Baixando a lista de checksums: ${sums_url}"
  if ! curl -fsSL --retry 3 -o "$sums_file" "$sums_url"; then
    log_error "Falha ao baixar ${sums_url}"
    log_error "Use --iso /caminho/para/debian-netinst.iso para trabalhar offline."
    exit 1
  fi

  local entry
  if [[ -n "$ISO_URL" ]]; then
    local want; want="$(basename "$ISO_URL")"
    entry="$(awk -v w="$want" '$2 ~ w"$" {print $1" "$2; exit}' "$sums_file")"
  else
    entry="$(awk '$2 ~ /netinst\.iso$/ {print $1" "$2; exit}' "$sums_file")"
  fi

  if [[ -z "$entry" ]]; then
    log_error "Não encontrei um arquivo *netinst.iso em ${sums_url}"
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
    log_info "Baixando ${base_url}/${filename} (≈ 700 MB)…"
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
# Extrair, injetar e remontar
# ---------------------------------------------------------------------------
EXTRACT_DIR=""
ISO_ROOT=""

extract_iso() {
  section "Extração"
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
    log_error "Esta ferramenta só suporta a ISO **Debian netinst**. Para Ubuntu, ver docs/ISO.md."
    exit 1
  fi
  log_ok "ISO extraída em ${EXTRACT_DIR}"
}

inject_project() {
  section "Injeção do projeto"
  local dest="${ISO_ROOT}/ai-cpu-os"

  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] copiaria ${REPO_ROOT} → ${dest} (sem .git, sem iso/work, sem *.iso)"
    return 0
  fi

  mkdir -p "$dest"
  tar -C "$REPO_ROOT" -cf - \
      --exclude=./.git \
      --exclude=./iso/work \
      --exclude=./iso/out \
      --exclude='./*.iso' \
      . | tar -C "$dest" -xf -
  chmod +x "${dest}/build.sh" "${dest}/detect-hardware.sh" "${dest}/iso/firstboot.sh" 2>/dev/null || true
  log_ok "Projeto copiado para ${dest} ($(du -sh "$dest" | awk '{print $1}'))"
}

# Substitui tokens @@NOME@@ nos templates do preseed.
subst_template() {
  local src="$1" dst="$2"
  sed \
    -e "s|@@PROFILE@@|${PROFILE}|g" \
    -e "s|@@FIRSTBOOT_REBOOT@@|${FIRSTBOOT_REBOOT}|g" \
    -e "s|@@ISO_BUILD@@|${ISO_BUILD_ID}|g" \
    -e "s|@@USERNAME@@|${USERNAME}|g" \
    -e "s|@@USER_FULLNAME@@|${USER_FULLNAME}|g" \
    -e "s|@@PASSWORD_HASH@@|${PASSWORD_HASH}|g" \
    -e "s|@@LOCALE@@|${LOCALE}|g" \
    -e "s|@@LANG@@|${LANG_CODE}|g" \
    -e "s|@@COUNTRY@@|${COUNTRY}|g" \
    -e "s|@@KEYMAP@@|${KEYMAP}|g" \
    -e "s|@@TIMEZONE@@|${TIMEZONE}|g" \
    -e "s|@@MIRROR_HOST@@|${MIRROR_HOST}|g" \
    -e "s|@@MIRROR_DIR@@|${MIRROR_DIR}|g" \
    -e "s|@@GRUB_WITH_OTHER_OS@@|${GRUB_WITH_OTHER_OS}|g" \
    -e "s|@@EXTRA_PACKAGES@@|${EXTRA_PACKAGES}|g" \
    -e "s|@@PARTMAN_DISK@@|${PARTMAN_DISK_LINE}|g" \
    "$src" > "$dst"
}

inject_preseed() {
  section "Injeção do preseed"
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
    log_info "[dry-run] disco: ${DISK:-<não fixado>} · perfil: ${PROFILE} · usuário: ${USERNAME}"
    return 0
  fi

  mkdir -p "$dest"
  subst_template "${ISO_DIR}/preseed/ai-cpu-os.cfg"        "${dest}/ai-cpu-os.cfg"
  subst_template "${ISO_DIR}/preseed/late-command.sh"      "${dest}/late-command.sh"
  subst_template "${ISO_DIR}/preseed/firstboot.sh"         "${dest}/firstboot.sh"
  cp "${ISO_DIR}/preseed/ai-cpu-os-firstboot.service"      "${dest}/ai-cpu-os-firstboot.service"
  chmod 0644 "${dest}/ai-cpu-os.cfg" "${dest}/ai-cpu-os-firstboot.service"
  chmod 0755 "${dest}/late-command.sh" "${dest}/firstboot.sh"

  # Rede de segurança: se algum marcador REAL sobrou, o preseed não funciona.
  # (Verificamos apenas os nomes esperados — comentários podem conter o
  #  formato, então um grep genérico por arrobas daria falso positivo.)
  local -a required_tokens=(
    PROFILE FIRSTBOOT_REBOOT ISO_BUILD USERNAME USER_FULLNAME PASSWORD_HASH
    LOCALE LANG COUNTRY KEYMAP TIMEZONE MIRROR_HOST MIRROR_DIR
    GRUB_WITH_OTHER_OS EXTRA_PACKAGES PARTMAN_DISK
  )
  local t leftover=0
  for t in "${required_tokens[@]}"; do
    if grep -q "@@${t}@@" "${dest}/"*.cfg "${dest}/"*.sh 2>/dev/null; then
      log_error "Marcador não substituído: @@${t}@@"
      leftover=1
    fi
  done
  if [[ $leftover -ne 0 ]]; then
    log_error "Isso indica um bug no build-iso.sh. Abortando para não gerar uma ISO quebrada."
    exit 1
  fi

  log_ok "Preseed gravado em ${dest} (todos os marcadores substituídos)."
}

patch_isolinux() {
  section "Boot BIOS (isolinux)"
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

patch_efi() {
  section "Boot UEFI"

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

detect_volume_id() {
  # Geramos um volume id próprio, determinístico e válido pelas regras do
  # ISO9660 (maiúsculas, dígitos e '_', até 32 caracteres). Reaproveitar o
  # volume id original do Debian é arriscado: ele contém espaços e minúsculas,
  # que o xorriso pode recusar no `-V`.
  printf '%s' "AI_CPU_OS_${PROFILE}" \
    | tr '[:lower:]' '[:upper:]' \
    | tr -c 'A-Z0-9_' '_' \
    | tr -s '_' \
    | cut -c1-32
}

repack_iso() {
  section "Remontagem da ISO"
  mkdir -p "$(dirname "$OUT_ISO")"

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

verify_output() {
  section "Verificação"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] verificaríamos a ISO gerada (preseed, projeto, boot)."
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

  if xorriso -indev "$OUT_ISO" -find /ai-cpu-os -type f >/dev/null 2>&1; then
    log_ok "Projeto presente em /ai-cpu-os na ISO."
  else
    log_warn "Não confirmei /ai-cpu-os na ISO gerada."
  fi
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

  log_info "dry_run=${DRY_RUN} · perfil=${PROFILE} · disco=${DISK:-<auto>} · saída=${OUT_ISO}"
  log_warn "A ISO gerada APAGA o disco indicado durante a instalação. Teste em VM primeiro!"

  if [[ "${EUID:-$(id -u)}" -ne 0 && $DRY_RUN -eq 0 ]]; then
    log_warn "Sem root: a extração/remontagem costuma funcionar, mas mtools pode reclamar."
  fi

  check_deps
  resolve_password
  acquire_iso
  extract_iso
  inject_project
  inject_preseed

  # Kernel/initrd são descobertos no patch do isolinux; rodamos primeiro.
  patch_isolinux
  patch_efi
  regenerate_md5sums

  VOLUME_ID="$(detect_volume_id)"
  log_info "Volume ID da ISO: '${VOLUME_ID}'"

  repack_iso
  verify_output

  section "Resumo"
  log_ok "ISO: ${OUT_ISO}"
  log_info "Perfil gravado: ${PROFILE} (auto = detecta o hardware no primeiro boot)"
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

main "$@"
