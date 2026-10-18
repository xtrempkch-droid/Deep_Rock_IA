#!/usr/bin/env bash
#
# mods/apt-sources/apply.sh — conserta o apt de uma máquina JÁ instalada
# -----------------------------------------------------------------------------
# POR QUE ESTA MOD EXISTE
#   Uma instalação feita com a ISO antiga ficou com o apt QUEBRADO: o
#   `late-command.sh` daquela época gravava
#       /etc/apt/sources.list.d/ai-cpu-os-local.list
#           deb [trusted=yes] file:///opt/apt-repo ./
#   sem verificar se o `/opt/apt-repo` realmente existia no alvo. Quando a
#   cópia falhava (ou o repositório não ia na mídia), TODO `apt-get update`
#   passava a falhar com "não possui um arquivo Release" — e, como o apt
#   aborta no erro, **nada** mais instalava: nem `openssh-server`, nem `git`.
#   O sintoma que o dono descreve é exatamente "o sistema não acha o
#   repositório, como se não houvesse link".
#
#   Outro caso, mais antigo: o `debian-installer` grava `deb cdrom:[…]` no
#   sources.list do alvo e, depois da instalação, a mídia não existe mais.
#
# O QUE ELA FAZ
#   1. Lista TODAS as fontes (.list e .sources) e mostra qual arquivo manda.
#   2. Remove (com backup) as que não podem funcionar:
#        * `file://` cujo caminho NÃO existe;
#        * `cdrom:` (a mídia já foi embora);
#        * `deb822` (.sources) sem `URIs:` ou com caminho inexistente.
#   3. Testa o conjunto: `apt-get update` de verdade. Se sobrar zero fonte
#      utilizável, grava a lista OFICIAL da distro detectada
#      (ubuntu: archive.ubuntu.com + security/updates; debian: deb.debian.org +
#      security).
#   4. Roda `apt-get update` de novo e diz, em uma linha, se o apt está OK.
#
# Tudo é reversível: cada arquivo alterado/removido fica em
# `<arquivo>.ai-cpu-os.bak` (o `revert.sh` restaura).
#
# Uso:
#   sudo bash mods/apt-sources/apply.sh              # conserta o sistema atual
#   sudo bash mods/apt-sources/apply.sh --dry-run    # só mostra o diagnóstico
#   sudo bash mods/apt-sources/apply.sh --root /mnt/alvo
# -----------------------------------------------------------------------------

set -euo pipefail

TARGET_ROOT="/"
DRY_RUN=0
FORCE_OFFICIAL=0

log()   { printf '[apt-sources] %s\n' "$*"; }
warn()  { printf '[apt-sources] AVISO: %s\n' "$*" >&2; }
error() { printf '[apt-sources] ERRO: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Uso: sudo bash mods/apt-sources/apply.sh [opções]

  --root DIR        Aplica em outro sistema (disco montado); padrão: /
  --official        Grava a lista oficial da distro mesmo se houver fontes boas
  --dry-run         Só diagnostica: não altera nada
  -h, --help        Esta ajuda
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)     [[ $# -ge 2 ]] || { error "--root exige um diretório"; exit 2; }
                TARGET_ROOT="${2%/}"; shift 2 ;;
    --official) FORCE_OFFICIAL=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          error "opção desconhecida: $1"; usage; exit 2 ;;
  esac
done

[[ -d "$TARGET_ROOT" ]] || { error "diretório inexistente: $TARGET_ROOT"; exit 2; }
[[ "$TARGET_ROOT" == "/" ]] || TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd)"

APT_DIR="${TARGET_ROOT:+${TARGET_ROOT%/}}/etc/apt"
LIST_DIR="${APT_DIR}/sources.list.d"

if [[ ! -d "$APT_DIR" ]]; then
  error "${APT_DIR} não existe: isto não parece um sistema Debian/Ubuntu."
  exit 1
fi

# Um comando DENTRO do alvo: no sistema em execução é direto; num disco montado
# usamos `chroot` (o apt precisa do seu próprio root para o dpkg).
in_target() {
  if [[ "$TARGET_ROOT" == "/" ]]; then
    "$@"
  else
    chroot "$TARGET_ROOT" "$@"
  fi
}

backup() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -f "${f}.ai-cpu-os.bak" ]] && return 0
  cp -a "$f" "${f}.ai-cpu-os.bak"
  log "backup: ${f}.ai-cpu-os.bak"
}

# ---------------------------------------------------------------------------
# 1. Diagnóstico: o que está configurado e o que aponta para lugar nenhum
# ---------------------------------------------------------------------------
log "=== fontes do apt em ${APT_DIR} ==="
shopt -s nullglob
mapfile -t LIST_FILES < <(printf '%s\n' "${APT_DIR}/sources.list" "${LIST_DIR}"/*.list "${LIST_DIR}"/*.sources 2>/dev/null)
shopt -u nullglob

if [[ ${#LIST_FILES[@]} -eq 0 ]]; then
  warn "nenhum arquivo de fontes encontrado."
fi

REMOVED=0
for f in "${LIST_FILES[@]}"; do
  [[ -f "$f" ]] || continue

  if [[ "$f" == *.sources ]]; then
    # Formato deb822: a URI fica em `URIs:`
    uris="$(sed -n 's/^URIs:[[:space:]]*//p' "$f" | tr -s ' \t' '\n' | grep -v '^$' || true)"
    if [[ -z "$uris" ]]; then
      warn "${f}: .sources SEM 'URIs:' (o apt falha ao lê-lo)"
      if [[ $DRY_RUN -eq 0 ]]; then
        backup "$f"
        rm -f "$f"
        REMOVED=$((REMOVED+1))
      fi
      continue
    fi
    bad=""
    while read -r u; do
      [[ -z "$u" ]] && continue
      case "$u" in
        file:*)
          p="${u#file:}"; p="${p#//}"
          if [[ ! -d "${TARGET_ROOT}${p}" ]]; then bad="$u"; fi ;;
        cdrom:*) bad="$u" ;;
      esac
    done <<< "$uris"
    if [[ -n "$bad" ]]; then
      warn "${f}: aponta para algo que não existe (${bad})"
      if [[ $DRY_RUN -eq 0 ]]; then
        backup "$f"
        rm -f "$f"
        REMOVED=$((REMOVED+1))
      fi
    else
      log "ok: ${f}"
    fi
    continue
  fi

  # .list: uma fonte por linha "deb [opções] URI SUITE [componentes]"
  keep=""
  dropped=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ""|\#*) keep+="${line}"$'\n'; continue ;;
    esac
    # Tira o "deb"/"deb-src" e o bloco de opções "[...]", e fica com a URI.
    uri="$(printf '%s' "$line" \
      | sed -E 's/^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?//' \
      | awk '{print $1}')"
    case "$uri" in
      cdrom:*)
        dropped+="${line}"$'\n' ;;
      file:*)
        p="${uri#file:}"; p="${p#//}"
        if [[ -d "${TARGET_ROOT}${p}" ]]; then
          keep+="${line}"$'\n'
        else
          dropped+="${line}"$'\n'
        fi ;;
      *)
        keep+="${line}"$'\n' ;;
    esac
  done < "$f"

  if [[ -n "$dropped" ]]; then
    warn "${f}: removendo fonte(s) que não existem:"
    printf '%s' "$dropped" | sed 's/^/           /' >&2
    if [[ $DRY_RUN -eq 0 ]]; then
      backup "$f"
      if printf '%s' "$keep" | grep -qE '^[[:space:]]*deb[[:space:]]'; then
        printf '%s' "$keep" > "$f"
      else
        # Sem nenhuma fonte sobrando, o arquivo vazio só confunde: remove.
        # (O backup já foi feito; o `revert.sh` devolve.)
        rm -f "$f"
      fi
      REMOVED=$((REMOVED+1))
    fi
  else
    log "ok: ${f}"
  fi
done

# ---------------------------------------------------------------------------
# 2. Sobrou alguma fonte utilizável? Se nada sobrar, grava a oficial.
# ---------------------------------------------------------------------------
has_http_source() {
  local f
  for f in "$APT_DIR/sources.list" "$LIST_DIR"/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE '^[[:space:]]*deb[[:space:]]' "$f" 2>/dev/null && return 0
  done
  for f in "$LIST_DIR"/*.sources; do
    [[ -f "$f" ]] || continue
    grep -qE '^URIs:[[:space:]]*https?://' "$f" 2>/dev/null && return 0
  done
  return 1
}

official_sources() {
  # Detecta a distro DENTRO do alvo (não a do host que roda o script).
  local id="" codename=""
  if [[ -f "${TARGET_ROOT}/etc/os-release" ]]; then
    id="$(sed -n 's/^ID=//p' "${TARGET_ROOT}/etc/os-release" | tr -d '"' | head -1)"
    codename="$(sed -n 's/^VERSION_CODENAME=//p' "${TARGET_ROOT}/etc/os-release" | tr -d '"' | head -1)"
  fi
  [[ -n "$codename" ]] || { error "não consegui descobrir a release do alvo (VERSION_CODENAME)."; return 1; }

  local body=""
  case "$id" in
    ubuntu)
      body="# ai-cpu-os: lista oficial (gravada por mods/apt-sources)
deb http://archive.ubuntu.com/ubuntu ${codename} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${codename}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
"
      ;;
    debian|*)
      body="# ai-cpu-os: lista oficial (gravada por mods/apt-sources)
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
"
      ;;
  esac

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[dry-run] gravaria ${APT_DIR}/sources.list com a lista oficial de ${id} ${codename}"
    return 0
  fi
  backup "${APT_DIR}/sources.list"
  printf '%s' "$body" > "${APT_DIR}/sources.list"
  log "lista oficial de ${id} ${codename} gravada em ${APT_DIR}/sources.list"
}

if [[ $FORCE_OFFICIAL -eq 1 ]]; then
  official_sources || exit 1
elif ! has_http_source; then
  warn "nenhuma fonte utilizável sobrou; gravando a lista oficial da distro"
  official_sources || exit 1
fi

# ---------------------------------------------------------------------------
# 3. Prova real: o apt consegue atualizar?
# ---------------------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  log "[dry-run] não executei 'apt-get update' (${REMOVED} arquivo(s) seriam alterados)."
  exit 0
fi

## O teste REAL precisa executar o apt DENTRO do alvo. Num disco montado isso
## exige `chroot` (root). Sem essa capacidade — árvore de teste, container sem
## CAP_SYS_CHROOT — degradamos com aviso em vez de falhar: o diagnóstico e as
## correções já foram feitos e são úteis por si (Regra 13-a).
if ! in_target true >/dev/null 2>&1; then
  warn "não consigo executar comandos em ${TARGET_ROOT} (chroot sem permissão?)."
  warn "as fontes foram corrigidas, mas o teste com 'apt-get update' foi PULADO."
  log "pronto (${REMOVED} arquivo(s) alterados). Rode 'apt-get update' para conferir."
  exit 0
fi

log "testando com 'apt-get update'…"
if in_target apt-get update -qq 2>&1 | tee /tmp/apt-sources-update.log | tail -5; then
  if in_target apt-get update -qq >/dev/null 2>&1; then
    log "OK: o apt está atualizando normalmente."
    exit 0
  fi
fi

error "'apt-get update' AINDA falha. Últimas linhas:"
tail -15 /tmp/apt-sources-update.log >&2 || true
cat >&2 <<'EOF'

Se a mensagem for de DNS/rede ("Temporary failure resolving", "Network is
unreachable"), o problema NÃO é o sources.list:

  ip -4 route            # existe um 'default via ...'?
  ping -c1 8.8.8.8       # sai para fora?
  cat /etc/resolv.conf   # tem um 'nameserver' válido?

Para consertar a rede, use o mod dedicado:
  sudo bash mods/network/apply.sh --mode dhcp
EOF
exit 1
