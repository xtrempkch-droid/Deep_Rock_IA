#!/usr/bin/env bash
#
# iso/verify-iso.sh — verifica uma ISO gerada (ou uma árvore já extraída)
# -----------------------------------------------------------------------------
# Confere se a ISO realmente *é* o que prometemos: a config de instalação no
# lugar certo, o projeto embutido, os templates sem marcador sobrando, o YAML
# do autoinstall válido e coerente com as flags usadas, a entrada de boot
# automática e o Volume ID.
#
# Uso:
#   bash iso/verify-iso.sh --iso iso/out/ai-cpu-os-ubuntu-20261012.iso
#   bash iso/verify-iso.sh --dir iso/work/stage          # árvore já extraída
#
# Opções:
#   --iso PATH            ISO a verificar (usa xorriso, somente leitura).
#   --dir PATH            Árvore já extraída (NÃO precisa de xorriso/root).
#   --distro NAME         ubuntu (padrão) | debian | auto (deduz pelo conteúdo).
#   --disk PATH           Disco esperado na config (ex.: /dev/vda).
#   --role NAME           Papel esperado no .iso-config (auto = não conferir).
#   --family NAME         Família esperada no .iso-config (auto = não conferir).
#   --out DIR             Guarda os arquivos extraídos para inspeção.
#   --quiet               Só o resumo.
#   -h | --help           Esta ajuda.
#
# Por que existe o modo --dir: o xorriso não é obrigatório para verificar. Com
# --dir a mesma checagem roda em qualquer lugar (inclusive no CI, sobre a
# árvore que o próprio build-iso.sh produz) — é o que faz esta ferramenta ser
# testável em vez de "escrita e nunca executada".
#
# Saída: uma linha [PASS]/[FAIL]/[SKIP] por verificação e um resumo final.
# Exit code: 0 = tudo passou (SKIPs permitidos) · 1 = houve FAIL.
# -----------------------------------------------------------------------------

set -euo pipefail

MODE=""
INPUT=""
DISTRO="ubuntu"
EXPECT_DISK=""
EXPECT_ROLE="auto"
EXPECT_FAMILY="auto"
OUT_DIR=""
QUIET=0

PASS=0; FAIL=0; SKIP=0

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"; C_BOLD="\033[1m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""; C_BOLD=""
fi
log_info()  { [[ $QUIET -eq 1 ]] && return 0; printf '%b[i]%b %s\n' "$C_INFO" "$C_RESET" "$*"; }
log_warn()  { printf '%b[warn]%b %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
log_error() { printf '%b[erro]%b %s\n' "$C_ERR" "$C_RESET" "$*" >&2; }
section()   { [[ $QUIET -eq 1 ]] && return 0; printf '\n%b== %s ==%b\n' "$C_BOLD" "$*" "$C_RESET"; }

pass() { PASS=$((PASS+1)); printf '  %b[PASS]%b %s\n' "$C_OK"  "$C_RESET" "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  %b[FAIL]%b %s\n' "$C_ERR" "$C_RESET" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  %b[SKIP]%b %s\n' "$C_WARN" "$C_RESET" "$1"; }

usage() {
  cat <<'EOF'
verify-iso.sh — verifica uma ISO gerada (ou uma árvore extraída)

Uso:
  bash iso/verify-iso.sh --iso PATH [opções]
  bash iso/verify-iso.sh --dir PATH [opções]

Opções:
  --iso PATH     ISO a verificar (usa xorriso, somente leitura).
  --dir PATH     Árvore já extraída (não precisa de xorriso nem de root).
  --distro NAME  ubuntu (padrão) | debian | auto.
  --disk PATH    Disco esperado na config (ex.: /dev/vda).
  --role NAME    Papel esperado (auto = não conferir).
  --family NAME  Família esperada (auto = não conferir).
  --out DIR      Guarda os arquivos extraídos para inspeção.
  --quiet        Só o resumo final.
EOF
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso)    [[ $# -ge 2 ]] || { log_error "--iso exige valor"; exit 2; }; MODE="iso"; INPUT="$2"; shift 2 ;;
    --dir)    [[ $# -ge 2 ]] || { log_error "--dir exige valor"; exit 2; }; MODE="dir"; INPUT="$2"; shift 2 ;;
    --distro) [[ $# -ge 2 ]] || { log_error "--distro exige valor"; exit 2; }; DISTRO="$2"; shift 2 ;;
    --disk)   [[ $# -ge 2 ]] || { log_error "--disk exige valor"; exit 2; }; EXPECT_DISK="$2"; shift 2 ;;
    --role)   [[ $# -ge 2 ]] || { log_error "--role exige valor"; exit 2; }; EXPECT_ROLE="$2"; shift 2 ;;
    --family) [[ $# -ge 2 ]] || { log_error "--family exige valor"; exit 2; }; EXPECT_FAMILY="$2"; shift 2 ;;
    --out)    [[ $# -ge 2 ]] || { log_error "--out exige valor"; exit 2; }; OUT_DIR="$2"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
  esac
done

case "$DISTRO" in
  ubuntu|debian|auto) ;;
  *) log_error "--distro inválido: '${DISTRO}' (use ubuntu, debian ou auto)."; exit 2 ;;
esac

if [[ -z "$MODE" ]]; then
  log_error "Informe --iso PATH ou --dir PATH. Use --help."
  exit 2
fi

if [[ "$MODE" == "iso" ]]; then
  [[ -f "$INPUT" ]] || { log_error "ISO não encontrada: ${INPUT}"; exit 2; }
  command -v xorriso >/dev/null 2>&1 || {
    log_error "xorriso não encontrado (necessário para --iso)."
    log_error "Instale com: apt-get install -y xorriso"
    log_error "Alternativa sem root: extraia a ISO e use --dir /caminho/extraido"
    exit 3
  }
else
  [[ -d "$INPUT" ]] || { log_error "Diretório não encontrado: ${INPUT}"; exit 2; }
fi

# ---------------------------------------------------------------------------
# Área de trabalho com os arquivos que vamos inspecionar
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
readonly WORK
cleanup() {
  if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    cp -a "${WORK}/." "$OUT_DIR/" 2>/dev/null || true
    log_info "Arquivos inspecionados copiados para ${OUT_DIR}"
  fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# Extrai um caminho absoluto de dentro da ISO/árvore para o WORK.
# Uso: fetch <caminho-absoluto-na-midia> → imprime o caminho local (stdout) ou
# nada se não existir.
fetch() {
  local abs="$1" dest
  dest="${WORK}$(printf '%s' "$abs" | tr '/' '_')"
  if [[ "$MODE" == "dir" ]]; then
    [[ -e "${INPUT}${abs}" ]] || return 1
    cp -a "${INPUT}${abs}" "$dest" 2>/dev/null || return 1
  else
    xorriso -osirrox on -indev "$INPUT" -extract "$abs" "$dest" >/dev/null 2>&1 || return 1
  fi
  printf '%s' "$dest"
}

# fetch sem ruído, para quando só queremos saber se existe.
existe() {
  local d
  d="$(fetch "$1" 2>/dev/null)" || return 1
  [[ -n "$d" ]]
}

# Lista caminhos de dentro da ISO via -find, SEM as aspas simples que o xorriso
# (1.5.x) coloca em volta de cada resultado: ele imprime '/apt-repo/x.deb', e
# comparar isso com o caminho puro do índice ('x.deb') nunca casa. Só o modo
# --iso sofre (o --dir usa `find`, sem aspas) — foi o que fez 408 falsos
# "repositório incompleto" na primeira verificação de uma ISO real.
xfind() {
  xorriso -osirrox on -indev "$INPUT" -find "$@" 2>/dev/null \
    | sed -e "s/^'//" -e "s/'$//"
}

check_file() {
  local abs="$1" desc="$2"
  if existe "$abs"; then
    pass "${desc} (${abs})"
  else
    fail "${desc} — AUSENTE (${abs})"
  fi
}

log_info "Verificando ${MODE}: ${INPUT}"

# ---------------------------------------------------------------------------
# 1. Deduzir a distro pelo conteúdo, se pedido
# ---------------------------------------------------------------------------
if [[ "$DISTRO" == "auto" ]]; then
  if existe "/autoinstall.yaml"; then
    DISTRO="ubuntu"
  elif existe "/preseed/ai-cpu-os.cfg"; then
    DISTRO="debian"
  else
    log_error "Não achei nem /autoinstall.yaml nem /preseed/ai-cpu-os.cfg."
    log_error "A ISO não tem configuração de instalação automática. Abortando."
    exit 1
  fi
  log_info "Distro deduzida pelo conteúdo: ${DISTRO}"
fi

# ---------------------------------------------------------------------------
# 2. Configuração de instalação
# ---------------------------------------------------------------------------
section "Configuração de instalação (${DISTRO})"
if [[ "$DISTRO" == "ubuntu" ]]; then
  check_file "/autoinstall.yaml" "autoinstall.yaml na raiz da ISO (ao lado de casper/)"
else
  check_file "/preseed/ai-cpu-os.cfg" "Preseed do debian-installer"
fi

# ---------------------------------------------------------------------------
# 3. Projeto embutido
# ---------------------------------------------------------------------------
section "Projeto embutido (/ai-cpu-os)"
# Lista derivada de .github/workflows/validate.yml (os mesmos arquivos que o
# CI exige no repositório) + os que a ISO precisa ter executáveis.
for f in \
  build.sh detect-hardware.sh llama-build.sh \
  families/resolve.sh families/_base/family.conf families/intel-broadwell/family.conf \
  mods/apply.sh mods/kernel-tuning/mod.conf mods/openblas-threads/apply.sh \
  mods/network/mod.conf mods/network/apply.sh \
  roles/inference/install.sh roles/builder/install.sh \
  tests/smoke-test.sh \
  ; do
  check_file "/ai-cpu-os/${f}" "projeto: ${f}"
done

# ---------------------------------------------------------------------------
# 4. Templates compartilhados + marcadores
# ---------------------------------------------------------------------------
section "Templates e marcadores"
for f in preseed/late-command.sh preseed/firstboot.sh preseed/ai-cpu-os-firstboot.service; do
  check_file "/${f}" "template: ${f}"
done

LEFT=""
for f in preseed/late-command.sh preseed/firstboot.sh; do
  d="$(fetch "/${f}" 2>/dev/null || true)"
  [[ -n "$d" ]] || continue
  # Só tokens reais do formato @@NOME@@ importam; comentários usam o mesmo
  # formato de propósito (documentação), então isto é uma busca estrita.
  found="$(grep -o '@@[A-Z_][A-Z_0-9]*@@' "$d" | sort -u | tr '\n' ' ' || true)"
  if [[ -n "$found" ]]; then
    LEFT="${LEFT} ${f}:${found}"
  fi
done
if [[ -z "$LEFT" ]]; then
  pass "nenhum marcador @@TOKEN@@ sobrou nos templates (a ISO não quebraria no alvo)"
else
  fail "marcadores não substituídos:${LEFT}"
fi

# ---------------------------------------------------------------------------
# 4-b. Modelo embutido na mídia (air-gapped)
# ---------------------------------------------------------------------------
# A ISO deve funcionar SEM internet, então o modelo não pode ser baixado no 1º
# boot: ou ele está na mídia, ou o alvo sobe sem LLM (mas nunca "baixa sozinho").
# Verificamos dois aspectos distintos:
#   (a) a LIGAÇÃO — o instalador copia /models para o alvo e o 1º boot usa esse
#       arquivo sem rede (se alguém remover isso, a ISO volta a depender de rede);
#   (b) o CONTEÚDO — se há um .gguf na mídia, ele parece mesmo um GGUF?
section "Modelo embutido (/models) e caminho offline"

# (LATE_LOCAL é definido mais abaixo, para a seção de YAML; aqui buscamos de
#  novo porque este trecho roda antes e a variável ainda não existe.)
MODEL_LATE="$(fetch "/preseed/late-command.sh" 2>/dev/null || true)"

if [[ -n "$MODEL_LATE" ]] && grep -q '/models' "$MODEL_LATE"; then
  pass "late-command copia o modelo da mídia para o alvo"
else
  fail "late-command NÃO menciona /models: o modelo (se houver) não chegaria ao alvo"
fi
if [[ -n "$MODEL_LATE" ]] && grep -q 'MODEL_FILE' "$MODEL_LATE"; then
  pass "late-command registra MODEL_FILE para o primeiro boot"
else
  fail "late-command não registra MODEL_FILE no .iso-config"
fi

FIRST_LOCAL="$(fetch "/preseed/firstboot.sh" 2>/dev/null || true)"
if [[ -n "$FIRST_LOCAL" ]] && grep -q 'AI_MODEL_FILE' "$FIRST_LOCAL"; then
  pass "firstboot repassa o modelo local (AI_MODEL_FILE) — sem download"
else
  fail "firstboot não repassa AI_MODEL_FILE: o modelo da mídia seria ignorado"
fi

# Conteúdo: procura um .gguf na mídia (pode legitimamente não existir).
MODEL_LIST=""
if [[ "$MODE" == "dir" ]]; then
  MODEL_LIST="$(find "${INPUT}/models" -maxdepth 1 -name '*.gguf' -type f 2>/dev/null || true)"
else
  MODEL_LIST="$(xfind /models -name '*.gguf' | grep '\.gguf$' || true)"
fi

if [[ -z "$MODEL_LIST" ]]; then
  skip "nenhum .gguf na mídia (ISO gerada com --iso-model none) — caminho offline não exercitado"
else
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue
    if [[ "$MODE" == "dir" ]]; then
      src="$m"
    else
      src="$(fetch "$m" 2>/dev/null || true)"
    fi
    [[ -n "$src" && -f "$src" ]] || { fail "não consegui extrair o modelo ${m}"; continue; }
    magic="$(head -c 4 "$src" 2>/dev/null || true)"
    size_mb=$(( $(stat -c %s "$src" 2>/dev/null || echo 0) / 1024 / 1024 ))
    if [[ "$magic" != "GGUF" ]]; then
      fail "modelo ${m}: magic '${magic}' em vez de 'GGUF' (arquivo inválido na mídia)"
    elif (( size_mb < 10 )); then
      fail "modelo ${m}: ${size_mb} MB — pequeno demais para ser um modelo útil"
    else
      pass "modelo ${m}: GGUF válido, ${size_mb} MB, sem depender de rede"
    fi
  done <<< "$MODEL_LIST"
fi

# ---------------------------------------------------------------------------
# 4-b-bis. Fonte do llama.cpp (/llama-src.tar.gz)
# ---------------------------------------------------------------------------
# O llama.cpp e compilado no 1o boot; se o tarball estiver na midia, esse
# passo nao precisa de rede. Verificamos a CORRENTE (o late-command copia e o
# firstboot usa via --source/AI_LLAMA_SOURCE) e o CONTEUDO (e mesmo um tarball
# com o fonte?).
section "Fonte do llama.cpp na midia (/llama-src.tar.gz)"

SRC_LATE="$(fetch "/preseed/late-command.sh" 2>/dev/null || true)"
SRC_FIRST="$(fetch "/preseed/firstboot.sh" 2>/dev/null || true)"

# Elos da corrente (o firstboot foi substituido: deve conter a variavel LLAMA_SRC).
if [[ -n "$SRC_LATE" ]] && grep -q 'llama-src' "$SRC_LATE"; then
  pass "late-command copia a fonte do llama.cpp da midia para o alvo"
else
  fail "late-command NAO menciona llama-src: a fonte (se houver) nao chegaria ao alvo"
fi
if [[ -n "$SRC_LATE" ]] && grep -q 'LLAMA_SRC' "$SRC_LATE"; then
  pass "late-command registra LLAMA_SRC para o primeiro boot"
else
  fail "late-command nao registra LLAMA_SRC no .iso-config"
fi
if [[ -n "$SRC_FIRST" ]] && grep -q 'AI_LLAMA_SOURCE' "$SRC_FIRST"; then
  pass "firstboot usa a fonte local (AI_LLAMA_SOURCE) -- compila sem rede"
else
  fail "firstboot nao usa AI_LLAMA_SOURCE: a fonte da midia seria ignorada (e o build exigiria rede)"
fi

# Conteudo: procura o tarball na midia (pode legitimamente nao existir).
SRC_TARBALL=""
if [[ "$MODE" == "dir" ]]; then
  for f in "${INPUT}/llama-src.tar.gz" "${INPUT}/llama-src.tgz"; do
    [[ -f "$f" ]] && SRC_TARBALL="$f" && break
  done
else
  for f in /llama-src.tar.gz /llama-src.tgz; do
    if existe "$f"; then SRC_TARBALL="$(fetch "$f" 2>/dev/null || true)"; break; fi
  done
fi

if [[ -z "$SRC_TARBALL" || ! -f "$SRC_TARBALL" ]]; then
  skip "nenhuma fonte do llama.cpp na midia (--iso-source none) -- o 1o boot exige rede"
else
  # tar -tf lista o conteudo; falha se o arquivo estiver corrompido/truncado.
  if TAR_LIST="$(tar -tf "$SRC_TARBALL" 2>/dev/null)"; then
    N_FILES="$(printf '%s
' "$TAR_LIST" | wc -l)"
    SRC_MB=$(( $(stat -c %s "$SRC_TARBALL" 2>/dev/null || echo 0) / 1024 / 1024 ))
    if (( N_FILES > 100 )); then
      pass "fonte do llama.cpp: tarball valido, ${N_FILES} arquivos, ${SRC_MB} MB"
    else
      fail "fonte do llama.cpp: tarball com apenas ${N_FILES} arquivos -- nao parece o llama.cpp"
    fi
    # `<<<` (here-string) e NÃO `printf … | grep -q`: com `set -o pipefail`,
    # o `grep -q` sai no 1º match, o `printf` leva SIGPIPE (141) e o pipeline
    # inteiro "falha" — o `if` cairia no else e acusaria a fonte. Vale para
    # qualquer lista que passe de ~64 KB (o buffer do pipe). Mesma armadilha do
    # `find | head` já registrada no JOURNAL § 6.
    if grep -qE '(^|/)CMakeLists\.txt$' <<<"$TAR_LIST"; then
      pass "a fonte tem CMakeLists.txt (e compilavel)"
    else
      fail "a fonte nao tem CMakeLists.txt -- o 1o boot falharia ao compilar"
    fi
    if grep -qE '(^|/)ggml/' <<<"$TAR_LIST"; then
      pass "a fonte contem ggml/ (arvore do llama.cpp)"
    else
      fail "a fonte nao contem ggml/ -- nao parece o llama.cpp"
    fi
  else
    fail "fonte do llama.cpp: /llama-src.tar.gz nao e um tarball legivel (truncado?)"
  fi
fi

# ---------------------------------------------------------------------------
# 4-c. Repositório apt local (/apt-repo) — o que torna a instalação offline
# ---------------------------------------------------------------------------
# Invariantes que valem a pena vigiar (o modo de falha é silencioso ou tardio):
#   1. o índice existe e o apt consegue lê-lo (Packages.gz de gzip válido);
#   2. TODO .deb citado no índice está de fato na mídia — um repositório
#      incompleto só aparece como "não instala sem rede" bem depois;
#   3. os .deb parecem .deb (magic `!<arch>`) — pega download que trouxe uma
#      página de erro HTML com nome de .deb;
#   4. a CONFIGURAÇÃO e a MÍDIA concordam: repositório embutido exige a fonte
#      extra no autoinstall, e fonte extra exige o repositório embutido.
section "Repositório apt local (/apt-repo)"

REPO_GZ="$(fetch "/apt-repo/Packages.gz" 2>/dev/null || true)"

# ⚠️ A CONFIGURAÇÃO É DISTRO-DEPENDENTE — e conferir só o autoinstall dava
# FALSO POSITIVO no caminho Debian (run #10 do CI: "2 problema(s)", sendo um
# deles "o repositório está na mídia mas o autoinstall NÃO o usa"). O repositório
# estava na mídia e a preseed O USAVA; simplesmente não existe autoinstall numa
# ISO Debian. Sintoma confuso: o build gerava a ISO e o verificador a reprovava.
#   - Ubuntu: fonte extra na seção `sources` do curtin, dentro do autoinstall;
#   - Debian: `d-i apt-setup/local0/repository` na preseed.
# O modo de falha que a checagem existe para pegar (config sem a fonte extra,
# deixando a instalação dependente de rede) continua coberto nos dois caminhos.
if [[ "$DISTRO" == "debian" ]]; then
  CFG_FOR_REPO="$(fetch "/preseed/ai-cpu-os.cfg" 2>/dev/null || true)"
  CFG_REPO_MARKER='apt-setup/local0/repository'
  CFG_NAME="a preseed"
  if [[ -n "$CFG_FOR_REPO" ]] && grep -q "$CFG_REPO_MARKER" "$CFG_FOR_REPO"; then
    AI_WANTS_REPO=1
  else
    AI_WANTS_REPO=0
  fi
else
  # Ubuntu: a fonte local NÃO entra no apt do INSTALADOR (o curtin roda o
  # `apt-get update` dentro de um chroot no alvo, sem /cdrom — foi bug real ao
  # bootar a ISO). O repositório é carregado para o alvo pelo late-command.sh
  # (/opt/apt-repo) e usado no PRIMEIRO BOOT. Então a "config" que importa é o
  # late-command, e ele só é exigido quando o repositório VEIO na mídia.
  CFG_FOR_REPO="$(fetch "/preseed/late-command.sh" 2>/dev/null || true)"
  CFG_REPO_MARKER='/opt/apt-repo'
  CFG_NAME="o late-command"
  if [[ -n "$REPO_GZ" ]] && [[ -n "$CFG_FOR_REPO" ]]; then
    AI_WANTS_REPO=1
  else
    AI_WANTS_REPO=0
  fi
fi

if [[ -z "$REPO_GZ" ]]; then
  if [[ $AI_WANTS_REPO -eq 1 ]]; then
    fail "${CFG_NAME} aponta para um repositório local, mas /apt-repo NÃO está na mídia (a instalação vai falhar)"
  else
    skip "nenhum repositório apt na mídia (--iso-repo none) — instalar pacotes exigirá rede"
  fi
else
  if ! gzip -t "$REPO_GZ" 2>/dev/null; then
    fail "/apt-repo/Packages.gz não é um gzip válido (índice corrompido)"
  else
    GZ_TXT="$(gzip -dc "$REPO_GZ" 2>/dev/null || true)"
    N_ENTRIES="$(printf '%s\n' "$GZ_TXT" | grep -c '^Package: ' || true)"
    if (( N_ENTRIES > 0 )); then
      pass "/apt-repo/Packages.gz: gzip válido com ${N_ENTRIES} pacote(s)"
    else
      fail "/apt-repo/Packages.gz não tem nenhuma entrada 'Package:'"
    fi

    # Lista de arquivos da mídia (uma chamada só; comparar em memória).
    if [[ "$MODE" == "dir" ]]; then
      REPO_FILES="$(find "${INPUT}/apt-repo" -type f 2>/dev/null | sed "s|^${INPUT}/apt-repo/||")"
    else
      REPO_FILES="$(xfind /apt-repo -type f | sed 's|^/apt-repo/||')"
    fi

    MISSING=0; N_DEB_INDEX=0
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      case "$rel" in *.deb) N_DEB_INDEX=$((N_DEB_INDEX + 1)) ;; esac
      if ! grep -qxF "$rel" <<<"$REPO_FILES"; then
        fail "o índice cita ${rel}, que NÃO está na mídia (repositório incompleto)"
        MISSING=$((MISSING + 1))
      fi
    done < <(printf '%s\n' "$GZ_TXT" | sed -n 's/^Filename: //p')

    N_DEB_MEDIA="$(printf '%s\n' "$REPO_FILES" | grep -c '\.deb$' || true)"
    if [[ $MISSING -eq 0 ]]; then
      pass "todos os ${N_DEB_INDEX} .deb do índice estão presentes na mídia (${N_DEB_MEDIA} arquivos .deb)"
    fi

    # Magic dos .deb: `!<arch>` (formato ar). Amostra no modo --iso (extrair
    # centenas de .deb seria caro); no modo --dir conferimos todos.
    BAD_MAGIC=0; CHECKED=0
    for rel in $(printf '%s\n' "$GZ_TXT" | sed -n 's/^Filename: //p'); do
      [[ "$rel" == *.deb ]] || continue
      if [[ "$MODE" == "iso" ]] && (( CHECKED >= 3 )); then break; fi
      if [[ "$MODE" == "dir" ]]; then
        d="${INPUT}/apt-repo/${rel}"
      else
        d="$(fetch "/apt-repo/${rel}" 2>/dev/null || true)"
      fi
      [[ -n "$d" && -f "$d" ]] || continue
      CHECKED=$((CHECKED + 1))
      if [[ "$(head -c 7 "$d" 2>/dev/null || true)" != '!<arch>' ]]; then
        fail "${rel} não é um .deb (magic esperado '!<arch>') — download inválido?"
        BAD_MAGIC=$((BAD_MAGIC + 1))
      fi
    done
    if [[ $BAD_MAGIC -eq 0 && $CHECKED -gt 0 ]]; then
      pass "amostra de ${CHECKED} .deb: magic '!<arch>' OK (arquivos íntegros)"
    fi

    if [[ $AI_WANTS_REPO -eq 1 ]] && grep -q "$CFG_REPO_MARKER" "$CFG_FOR_REPO"; then
      pass "${CFG_NAME} usa o repositório local (instalação/1º boot sem rede)"
    else
      fail "o repositório está na mídia mas ${CFG_NAME} NÃO o referencia (centenas de MB inúteis e alvo dependente de rede)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Conteúdo específico da distro
# ---------------------------------------------------------------------------
AI_LOCAL="$(fetch "/autoinstall.yaml" 2>/dev/null || true)"
PRESEED_LOCAL="$(fetch "/preseed/ai-cpu-os.cfg" 2>/dev/null || true)"
LATE_LOCAL="$(fetch "/preseed/late-command.sh" 2>/dev/null || true)"

section "Coerência da configuração"
if [[ "$DISTRO" == "ubuntu" && -n "$AI_LOCAL" ]]; then
  # Parse de verdade com PyYAML (yamllint valida estilo, não semântica).
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
    PY_ERR="$(python3 - "$AI_LOCAL" "$EXPECT_DISK" "$EXPECT_ROLE" "$EXPECT_FAMILY" <<'PY' 2>&1
import re, sys
import yaml

path, expect_disk, expect_role, expect_family = sys.argv[1:5]
problems = []

try:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:            # noqa: BLE001 - queremos a mensagem crua
    print(f"YAML inválido: {exc}")
    sys.exit(1)

if not isinstance(doc, dict):
    print("o topo do YAML não é um mapeamento")
    sys.exit(1)

def need(cond, msg):
    if not cond:
        problems.append(msg)

need(doc.get("version") == 1, f"version deveria ser 1 (achei {doc.get('version')!r})")

ident = doc.get("identity") or {}
need(bool(ident.get("username")), "identity.username ausente ou vazio")
pw = str(ident.get("password", ""))
need(bool(pw), "identity.password ausente")
# Segurança: a senha NUNCA vai em texto puro na mídia.
need(pw.startswith("$"), "identity.password não parece um hash crypt (vai em texto puro?)")

sto = doc.get("storage") or {}
lay = sto.get("layout") or {}
need(lay.get("name") == "direct", f"storage.layout.name deveria ser 'direct' (achei {lay.get('name')!r})")
match = lay.get("match") or {}
if expect_disk:
    need(match.get("path") == expect_disk,
         f"storage.layout.match.path deveria ser {expect_disk!r} (achei {match.get('path')!r})")
else:
    need(not match, f"sem --disk, o layout não deveria restringir disco (achei {match!r})")

lc = doc.get("late-commands")
need(isinstance(lc, list) and lc, "late-commands ausente ou vazio")
need(any("late-command.sh" in str(c) for c in (lc or [])),
     "late-commands não chama /cdrom/preseed/late-command.sh")
need(any("AI_CURTIN=1" in str(c) for c in (lc or [])),
     "late-commands não passa AI_CURTIN=1 (o wrapper in_target falharia)")

need(doc.get("shutdown") == "reboot", "shutdown deveria ser 'reboot' (é o que dispara o 1º boot)")

# O installer precisa achar o arquivo: sem isto, "instala e não explica".
need("casper" not in doc, "chave desconhecida 'casper' no topo do autoinstall")

for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
)" || true
    if [[ -z "$PY_ERR" ]]; then
      pass "autoinstall.yaml: YAML válido e semanticamente coerente"
      pass "senha como hash crypt (nunca texto puro)"
      pass "storage.layout.name = direct${EXPECT_DISK:+ + match.path = ${EXPECT_DISK}}"
      pass "late-commands chama o script com AI_CURTIN=1 e shutdown = reboot"
    else
      printf '%s\n' "$PY_ERR" | while IFS= read -r line; do
        [[ -n "$line" ]] && fail "autoinstall.yaml: ${line}"
      done
      # O `while` roda em subshell; o resumo precisa contar de verdade.
      FAIL=$((FAIL+1))
    fi
  else
    skip "PyYAML ausente: só a sintaxe pôde ser checada (instale python3-yaml)"
    if grep -q '^version: 1$' "$AI_LOCAL"; then
      pass "autoinstall.yaml: version: 1"
    else
      fail "autoinstall.yaml sem 'version: 1'"
    fi
  fi
fi

if [[ "$DISTRO" == "debian" && -n "$PRESEED_LOCAL" ]]; then
  if grep -q 'preseed/late_command' "$PRESEED_LOCAL"; then
    pass "preseed chama preseed/late_command (copia o projeto e arma o 1º boot)"
  else
    fail "preseed sem preseed/late_command"
  fi
  if [[ -n "$EXPECT_DISK" ]]; then
    if grep -q "partman-auto/disk string ${EXPECT_DISK}\$" "$PRESEED_LOCAL"; then
      pass "preseed fixa o disco em ${EXPECT_DISK}"
    else
      fail "preseed não fixa o disco em ${EXPECT_DISK} (verifique --disk no build)"
    fi
  else
    # Sem --disk não há o que comparar; o que importa é o preseed não deixar a
    # pergunta do particionamento em aberto SEM aviso. Fixar um disco é ótimo —
    # este ramo é o de quem só quer saber se a instalação é determinística.
    pre_disk="$(sed -nE 's/^d-i[[:space:]]+partman-auto\/disk[[:space:]]+string[[:space:]]+([^[:space:]]+).*/\1/p' "$PRESEED_LOCAL" | head -1)"
    if [[ -n "$pre_disk" ]]; then
      pass "preseed fixa o disco em ${pre_disk} (instalação determinística)"
    elif grep -qE '^#.*--allow-any-disk' "$PRESEED_LOCAL"; then
      pass "preseed sem disco fixo (--allow-any-disk explícito)"
    else
      fail "preseed sem disco fixo e sem o comentário de --allow-any-disk"
    fi
  fi
fi

section "Senha do root"
# O root é BLOQUEADO por padrão. Com --root-password-hash, o late-command
# aplica o hash via `chpasswd -e` (Ubuntu e Debian) e, no Debian, a preseed
# também habilita o login (root-login true). Aqui conferimos a COERÊNCIA entre
# os dois — é o tipo de coisa que o build não pega sozinho.
if [[ -n "$LATE_LOCAL" ]]; then
  # A linha tem de usar ASPAS SIMPLES: o hash crypt contém `$` (`$6$sal$…`) e,
  # entre aspas duplas, o shell expandiria `$6` ao ler o arquivo — sob `set -u`
  # o late-command.sh morre com exit 2 antes de copiar qualquer coisa
  # (sintoma: "Failed to run preseeded command … exit code 2", sessão #35).
  if grep -qE '^ROOT_PASSWORD_HASH="\$[0-9]+\$' "$LATE_LOCAL"; then
    fail "hash de root em ASPAS DUPLAS: o shell expande \$6 e o late-command morre em exit 2"
  elif grep -qE "^ROOT_PASSWORD_HASH='\\\$[0-9]+\\\$" "$LATE_LOCAL"; then
    pass "root habilitado: hash crypt no late-command"
    if grep -q 'chpasswd -e' "$LATE_LOCAL"; then
      pass "chpasswd -e define a senha do root (nunca texto puro)"
    else
      fail "hash de root sem o 'chpasswd -e' (o root ficaria bloqueado mesmo com hash)"
    fi
    if [[ "$DISTRO" == "debian" && -n "$PRESEED_LOCAL" ]]; then
      if grep -q 'passwd/root-login boolean true' "$PRESEED_LOCAL"; then
        pass "preseed: root-login true (coerente com o hash)"
      else
        fail "preseed com hash de root mas root-login false (incoerente)"
      fi
      if grep -qE 'passwd/root-password-crypted password \$' "$PRESEED_LOCAL"; then
        pass "preseed: senha do root como hash crypt"
      else
        fail "preseed sem root-password-crypted (ou o valor não é um hash crypt)"
      fi
    fi
  elif grep -qE "^ROOT_PASSWORD_HASH=''$" "$LATE_LOCAL"; then
    pass "root bloqueado (padrão: sem --root-password-hash)"
    if [[ "$DISTRO" == "debian" && -n "$PRESEED_LOCAL" ]] \
       && grep -q 'passwd/root-login boolean true' "$PRESEED_LOCAL"; then
      fail "preseed com root-login true mas SEM hash de root (incoerente)"
    fi
  else
    fail "late-command sem a linha ROOT_PASSWORD_HASH (template antigo?)"
  fi
else
  skip "sem late-command.sh para conferir a senha do root"
fi

section "Rede do sistema instalado"
# O Subiquity NÃO grava rede persistente no alvo quando o autoinstall não tem
# `network:` — o sistema sobe com a placa DOWN (bug real, sessão #33). A ISO
# agora carrega o netplan pronto em /preseed/ai-cpu-os-netplan.yaml e o
# late-command o copia para /etc/netplan/99-ai-cpu-os.yaml.
#
# ⚠️ DISTRO-AWARE, como o resto deste verificador: no **Debian** NÃO existe
# netplan no caminho — o d-i responde `netcfg` na preseed e escreve
# /etc/network/interfaces no alvo. Cobrar o netplan de uma ISO Debian reprovava
# uma ISO CORRETA (foi o que derrubou o build `--distro debian`, sessão #34).
# Cada distro é conferida pelo mecanismo que ela REALMENTE usa.
if [[ -n "$LATE_LOCAL" ]]; then
  if ! grep -qE "^NETWORK_MODE=['\"]" "$LATE_LOCAL"; then
    fail "late-command sem NETWORK_MODE (template antigo? o alvo pode subir sem rede)"
  else
    NETMODE="$(sed -n "s/^NETWORK_MODE=['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$LATE_LOCAL" | head -1)"
    NETPLAN_ISO="$(fetch "/preseed/ai-cpu-os-netplan.yaml" 2>/dev/null || true)"

    if [[ "$DISTRO" == "ubuntu" ]]; then
      # ---- Ubuntu: netplan na mídia + bloco network: no autoinstall ----
      case "$NETMODE" in
        auto|dhcp)
          pass "rede: modo ${NETMODE} (DHCP)"
          if [[ -z "$NETPLAN_ISO" ]]; then
            fail "rede ${NETMODE} sem /preseed/ai-cpu-os-netplan.yaml (o alvo subiria sem DHCP)"
          elif grep -q 'dhcp4: true' "$NETPLAN_ISO"; then
            pass "netplan do alvo tem dhcp4: true"
          else
            fail "netplan do alvo sem dhcp4: true (não pegaria IP por DHCP)"
          fi
          if [[ -n "$AI_LOCAL" ]]; then
            if grep -qE '^network:' "$AI_LOCAL" && grep -q 'dhcp4: true' "$AI_LOCAL"; then
              pass "autoinstall: bloco network com dhcp4 (instalador e alvo iguais)"
            else
              fail "autoinstall sem o bloco network/dhcp4 (instalador ficaria sem rede)"
            fi
          fi
          ;;
        static)
          pass "rede: modo static"
          if [[ -z "$NETPLAN_ISO" ]]; then
            fail "rede static sem /preseed/ai-cpu-os-netplan.yaml"
          elif grep -qE 'addresses: \[[0-9]' "$NETPLAN_ISO" && grep -q 'via: ' "$NETPLAN_ISO"; then
            pass "netplan do alvo tem endereço fixo e rota default"
          else
            fail "netplan static sem addresses/via"
          fi
          ;;
        none)
          pass "rede: modo none (comportamento antigo, sem configuração persistente)"
          if [[ -n "$AI_LOCAL" ]] && grep -qE '^network:' "$AI_LOCAL"; then
            fail "modo none mas o autoinstall tem bloco network (incoerente)"
          fi
          ;;
        *)
          fail "NETWORK_MODE desconhecido no late-command: '${NETMODE}'"
          ;;
      esac

      if [[ "$NETMODE" != "none" ]]; then
        if grep -q 'cloud.cfg.d/99-ai-cpu-os-disable-network.cfg' "$LATE_LOCAL"; then
          pass "cloud-init com a rede desligada (não reescreve o netplan)"
        else
          fail "sem cloud-init network disable: ele pode sobrescrever o netplan"
        fi
      fi

    else
      # ---- Debian: preseed (netcfg) é o mecanismo; netplan não entra ----
      if [[ -z "$PRESEED_LOCAL" ]]; then
        fail "preseed ausente: não há como conferir a rede do Debian"
      else
        case "$NETMODE" in
          auto|dhcp)
            pass "rede: modo ${NETMODE} (DHCP)"
            if grep -q 'netcfg/disable_autoconfig boolean false' "$PRESEED_LOCAL"; then
              pass "preseed: DHCP explícito (disable_autoconfig false)"
            else
              fail "preseed sem netcfg/disable_autoconfig false (rede indefinida)"
            fi
            if grep -q 'netcfg/dhcp_timeout' "$PRESEED_LOCAL"; then
              pass "preseed: dhcp_timeout definido (não trava esperando DHCP)"
            else
              fail "preseed sem netcfg/dhcp_timeout (boot pode travar esperando DHCP)"
            fi
            ;;
          static)
            pass "rede: modo static"
            if grep -q 'netcfg/disable_autoconfig boolean true' "$PRESEED_LOCAL"; then
              pass "preseed: autoconfig desligado (usa os campos estáticos)"
            else
              fail "preseed static sem netcfg/disable_autoconfig true"
            fi
            if grep -q 'netcfg/get_ipaddress string ' "$PRESEED_LOCAL" \
               && grep -q 'netcfg/get_gateway string ' "$PRESEED_LOCAL"; then
              pass "preseed: IP fixo + gateway definidos"
            else
              fail "preseed static sem get_ipaddress/get_gateway"
            fi
            if grep -q 'netcfg/get_netmask string ' "$PRESEED_LOCAL"; then
              pass "preseed: netmask definida (o d-i pede máscara, não /N)"
            else
              fail "preseed static sem get_netmask"
            fi
            if grep -q 'netcfg/get_nameservers string ' "$PRESEED_LOCAL"; then
              pass "preseed: nameservers definidos"
            else
              fail "preseed static sem get_nameservers (DNS não resolveria)"
            fi
            ;;
          none)
            pass "rede: modo none (o d-i decide sozinho, como antes)"
            ;;
          *)
            fail "NETWORK_MODE desconhecido no late-command: '${NETMODE}'"
            ;;
        esac

        if grep -qE '^d-i netcfg/choose_interface select ' "$PRESEED_LOCAL"; then
          pass "preseed: interface de rede escolhida explicitamente"
        else
          fail "preseed sem netcfg/choose_interface (o d-i pode perguntar)"
        fi
      fi

      # O netplan na mídia seria inútil no Debian; se aparecer, é sinal de que
      # alguém misturou os caminhos (e o late-command do Debian nem o lê).
      if [[ -n "$NETPLAN_ISO" && "$NETMODE" != "none" ]]; then
        pass "netplan na mídia (ignorado no Debian — a rede vem da preseed)"
      fi
    fi
  fi
else
  skip "sem late-command.sh para conferir a rede"
fi

# Papel/família gravados no template (o .iso-config nasce no alvo).
#
# Atenção: depois da substituição NÃO existe mais @@ROLE@@ no arquivo — é
# justamente o valor final que temos de conferir.
if [[ -n "$LATE_LOCAL" ]]; then
  if grep -q 'ROLE=%s' "$LATE_LOCAL"; then
    pass "late-command.sh grava ROLE no .iso-config"
  else
    fail "late-command.sh não grava ROLE no .iso-config"
  fi
  if grep -q 'FAMILY=%s' "$LATE_LOCAL"; then
    pass "late-command.sh grava FAMILY no .iso-config"
  else
    fail "late-command.sh não grava FAMILY no .iso-config"
  fi

  if [[ "$EXPECT_ROLE" != "auto" ]]; then
    if grep -q "\"${EXPECT_ROLE}\"" "$LATE_LOCAL"; then
      pass "late-command.sh grava ROLE=${EXPECT_ROLE}"
    else
      fail "late-command.sh não grava ROLE=${EXPECT_ROLE}"
    fi
  fi
  if [[ "$EXPECT_FAMILY" != "auto" ]]; then
    if grep -q "\"${EXPECT_FAMILY}\"" "$LATE_LOCAL"; then
      pass "late-command.sh grava FAMILY=${EXPECT_FAMILY}"
    else
      fail "late-command.sh não grava FAMILY=${EXPECT_FAMILY}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6. Entrada de boot automática
# ---------------------------------------------------------------------------
section "Boot"
if [[ "$DISTRO" == "ubuntu" ]]; then
  GRUB_LOCAL="$(fetch "/boot/grub/grub.cfg" 2>/dev/null || true)"
  if [[ -z "$GRUB_LOCAL" ]]; then
    skip "sem /boot/grub/grub.cfg para conferir (o menu vem de outro lugar)"
  else
    # `set default="ai-cpu-os-auto"` só resolve se existir uma menuentry com
    # esse `--id`. Sem ele o GRUB cai na entrada 0 (a interativa) e a
    # instalação automática não acontece — foi um bug REAL, invisível para um
    # `grep ai-cpu-os-auto` (que casava com o próprio `set default`).
    if grep -qE 'menuentry[^"]*"[^"]*"[^\{]*--id[ =]ai-cpu-os-auto' "$GRUB_LOCAL"; then
      pass "/boot/grub/grub.cfg tem a menuentry com --id 'ai-cpu-os-auto'"
    else
      fail "/boot/grub/grub.cfg SEM menuentry com --id 'ai-cpu-os-auto' (o 'set default' não casaria; o GRUB subiria a entrada interativa)"
    fi
    if grep -q 'set default="ai-cpu-os-auto"' "$GRUB_LOCAL"; then
      pass "set default aponta para 'ai-cpu-os-auto'"
    else
      fail "set default não aponta para 'ai-cpu-os-auto' (não instalaria sozinho)"
    fi
    if grep -q 'autoinstall' "$GRUB_LOCAL"; then
      pass "entrada usa o parâmetro de kernel 'autoinstall'"
    else
      fail "entrada sem o parâmetro 'autoinstall' (o Subiquity perguntaria tudo)"
    fi
    if grep -q 'casper/vmlinuz' "$GRUB_LOCAL"; then
      pass "entrada aponta para o kernel do live (/casper/vmlinuz)"
    else
      fail "entrada não aponta para /casper/vmlinuz"
    fi
  fi
else
  ISO_LOCAL="$(fetch "/isolinux/isolinux.cfg" 2>/dev/null || true)"
  if [[ -z "$ISO_LOCAL" ]]; then
    fail "sem /isolinux/isolinux.cfg (o Debian boota por isolinux)"
  else
    if grep -q 'ai-cpu-os-auto' "$ISO_LOCAL"; then
      pass "isolinux.cfg tem o label 'ai-cpu-os-auto'"
    else
      fail "isolinux.cfg SEM o label 'ai-cpu-os-auto'"
    fi
    if grep -q 'preseed/file=' "$ISO_LOCAL"; then
      pass "label passa preseed/file= (instalação automática)"
    else
      fail "label sem preseed/file="
    fi
    # `prompt 1` mostra "boot:" e ESPERA UMA TECLA — o `timeout` não vale nesse
    # modo. A ISO ficava parada nessa tela e o instalador nunca começava (VM
    # muda, disco intocado). Descoberto bootando a ISO Debian pela 1ª vez.
    if grep -qE '^[[:space:]]*prompt[[:space:]]+0' "$ISO_LOCAL"; then
      pass "isolinux.cfg com 'prompt 0' (boota sozinho, sem tecla)"
    else
      fail "isolinux.cfg sem 'prompt 0' (com 'prompt 1' o isolinux espera tecla e não instala)"
    fi
    # O `localechooser` é dos PRIMEIROS componentes do menu e roda ANTES de a
    # mídia ser montada, então idioma/teclado têm de vir na cmdline
    # (`env2debconf`, via /etc/preseed_aliases); o preseed ainda não foi lido.
    for _k in language keymap; do
      if grep -qE "^[[:space:]]*append[[:space:]].*[[:space:]]${_k}=[^[:space:]]+" "$ISO_LOCAL"; then
        pass "cmdline leva ${_k}= (o localechooser roda antes do preseed)"
      else
        fail "cmdline sem ${_k}= (o instalador pergunta e a instalação para)"
      fi
    done
  fi

  # A pergunta que o instalador REALMENTE exibe é `localechooser/languagelist`
  # (a lista), não `debian-installer/language`. Ela só é pulada quando o
  # idioma está entre as ESCOLHAS da lista, e a lista depende do nível de
  # exibição: em console serial o nível é 0 e só existe `en`. Sem responder a
  # lista, a interface ficava em português e MESMO ASSIM a pergunta aparecia e
  # travava tudo. Ver docs/TROUBLESHOOTING.md.
  PRE_LOCAL="$(fetch "/preseed/ai-cpu-os.cfg" 2>/dev/null || true)"
  if [[ -z "$PRE_LOCAL" ]]; then
    skip "sem /preseed/ai-cpu-os.cfg para conferir idioma do instalador"
  else
    pre_lang="$(sed -nE 's/^d-i[[:space:]]+debian-installer\/language[[:space:]]+(string|select)[[:space:]]+(.*[^[:space:]])[[:space:]]*$/\2/p' "$PRE_LOCAL" | head -1)"
    pre_list="$(sed -nE 's/^d-i[[:space:]]+localechooser\/languagelist[[:space:]]+(string|select)[[:space:]]+(.*[^[:space:]])[[:space:]]*$/\2/p' "$PRE_LOCAL" | head -1)"
    if [[ -z "$pre_list" ]]; then
      fail "preseed NÃO responde localechooser/languagelist (a lista de idiomas aparece e a instalação trava)"
    elif [[ "$pre_list" != "$pre_lang" ]]; then
      fail "localechooser/languagelist ('${pre_list}') difere de debian-installer/language ('${pre_lang}')"
    else
      pass "preseed responde localechooser/languagelist = '${pre_list}' (não pergunta o idioma)"
    fi
  fi

  # `grub-installer/bootdev` é pergunta CRÍTICA e o d-i a faz DEPOIS de copiar
  # o sistema inteiro: sem resposta, a instalação automática para em
  # "[!!] Configurando grub-pc" esperando um dispositivo (medido em VM).
  pre_bootdev="$(sed -nE 's/^d-i[[:space:]]+grub-installer\/bootdev[[:space:]]+(string|select)[[:space:]]+(.*[^[:space:]])[[:space:]]*$/\2/p' "$PRE_LOCAL" | head -1)"
  if [[ -z "$pre_bootdev" ]]; then
    fail "preseed NÃO responde grub-installer/bootdev (trava em 'Configurando grub-pc')"
  else
    pass "preseed responde grub-installer/bootdev = '${pre_bootdev}'"
  fi

  # `deb cdrom:` é gravado pelo PRÓPRIO instalador (`apt-cdrom-setup`) e não
  # tem relação com --iso-repo. Depois da instalação a mídia não existe mais:
  # `apt-get update` falha ("não tem um arquivo Release") e o primeiro boot do
  # papel `inference` aborta com rc=100 antes de instalar qualquer coisa.
  LATE_LOCAL="$(fetch "/preseed/late-command.sh" 2>/dev/null || true)"
  if [[ -z "$LATE_LOCAL" ]]; then
    skip "sem /preseed/late-command.sh para conferir a limpeza do apt"
  else
    if grep -qF "deb(-src)?[[:space:]]+cdrom:" "$LATE_LOCAL"; then
      pass "late-command.sh remove fontes 'cdrom:' do alvo (o 1º boot não quebra no apt update)"
    else
      fail "late-command.sh NÃO remove a fonte 'cdrom:' do alvo (o 1º boot aborta no apt update)"
    fi
    # Sem substituir o `20final-message` do d-i, o `finish-install` interpreta
    # o "back" da nota final como `exit 10` e ABORTA a instalação no menu
    # principal, em vez de reiniciar (medido em console serial).
    if grep -qF '20final-message' "$LATE_LOCAL"; then
      pass "late-command.sh substitui o 20final-message do d-i (reinicia em vez de parar no menu)"
    else
      fail "late-command.sh NÃO substitui o 20final-message (a instalação para no menu do d-i)"
    fi
    # O patch acima é só cinto de segurança: o `20final-message` é desempacotado
    # do udeb DEPOIS deste hook, então ele pode não estar lá a tempo. Quem
    # garante o reinício é a chamada explícita no fim do late-command.
    if grep -qE '^[[:space:]]*reboot -f' "$LATE_LOCAL"; then
      pass "late-command.sh reinicia o d-i explicitamente (não depende do finish-install)"
    else
      fail "late-command.sh NÃO reinicia explicitamente (a VM fica parada no menu do d-i)"
    fi
  fi

  # O marcador do 1º boot tem de chegar ao console SERIAL: no sistema
  # instalado `/dev/console` aponta para o ÚLTIMO `console=` da cmdline, e o
  # d-i grava `console=ttyS0,115200 console=tty1` (ou seja: tty1). Sem escrever
  # no ttyS0, o `test-vm.sh` fica esperando para sempre — medido na sessão #35,
  # com o trabalho JÁ concluído. Só os MARCADORES vão ao serial: espelhar o
  # build inteiro travou o console da VM.
  FIRSTBOOT_LOCAL="$(fetch "/preseed/firstboot.sh" 2>/dev/null || true)"
  if [[ -z "$FIRSTBOOT_LOCAL" ]]; then
    skip "sem /preseed/firstboot.sh para conferir o marcador no console serial"
  elif grep -qF '/dev/ttyS0' "$FIRSTBOOT_LOCAL"; then
    pass "firstboot.sh escreve o marcador no console serial (o teste de VM o vê)"
  else
    fail "firstboot.sh NÃO escreve no console serial (o teste de VM nunca vê o marcador)"
  fi
  # E o espelho do build INTEIRO no serial não pode voltar: megabytes no tty
  # travam o console da VM (nem as mensagens do kernel saem mais).
  if [[ -n "$FIRSTBOOT_LOCAL" ]] && grep -qF 'tee -a "$LOG" > /dev/ttyS0' "$FIRSTBOOT_LOCAL"; then
    fail "firstboot.sh espelha TODO o build no serial (trava o console da VM)"
  fi

  # `sudo` não vem na instalação padrão do Debian: sem ele, o usuário da ISO
  # (que é do grupo `sudo`) não administra nada, e com o root bloqueado o
  # sistema fica SEM acesso administrativo.
  if [[ -z "$PRE_LOCAL" ]]; then
    skip "sem preseed para conferir o pacote sudo"
  elif sed -nE 's|^d-i[[:space:]]+pkgsel/include[[:space:]]+string[[:space:]]+(.*)$|\1|p' "$PRE_LOCAL" | grep -qw 'sudo'; then
    pass "preseed instala 'sudo' (o usuário da ISO consegue administrar)"
  else
    fail "preseed NÃO instala 'sudo' (Debian não o traz; o usuário fica sem admin)"
  fi

  # Sem o preseed dentro do initrd, o `S30initrd-preseed` não acha nada: ele lê
  # literalmente `/preseed.cfg` NA RAIZ do initramfs (`preseed/file=` sozinho
  # só é aplicado depois, quando o udeb file-preseed instala — tarde demais).
  INITRD_LOCAL="$(fetch "/install.amd/initrd.gz" 2>/dev/null || true)"
  if [[ -z "$INITRD_LOCAL" ]]; then
    skip "sem /install.amd/initrd.gz para conferir o preseed embutido no initrd"
  else
    # Sem `grep -q` de propósito: com `pipefail`, sair cedo fecha o cano e o
    # gzip morre por SIGPIPE (141), derrubando um check que na verdade passou.
    n_pre="$(gzip -dc "$INITRD_LOCAL" 2>/dev/null | grep -acF 'preseed.cfg' || true)"
    if [[ "${n_pre:-0}" -gt 0 ]]; then
      pass "initrd tem /preseed.cfg na raiz (o S30initrd-preseed só lê a raiz)"
    else
      fail "initrd SEM /preseed.cfg na raiz (o preseed nunca é aplicado)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 7. Metadados da mídia (só no modo --iso)
# ---------------------------------------------------------------------------
section "Metadados da mídia"
if [[ "$MODE" == "iso" ]]; then
  # A etiqueta do xorriso é "Volume Id" (I maiúsculo). Com `/Volume id/`
  # case-sensitive o check nunca casava e a seção virava SKIP silencioso.
  voldid="$(xorriso -indev "$INPUT" -pvd_info 2>/dev/null | awk -F': *' '/Volume [Ii]d/{print $2}' | tr -d ' \r' || true)"
  if [[ -z "$voldid" ]]; then
    skip "não consegui ler o Volume ID"
  else
    log_info "Volume ID: ${voldid}"
    if [[ "$voldid" == AI_CPU_OS_* ]]; then
      pass "Volume ID com a nossa marca (${voldid})"
    else
      fail "Volume ID inesperado: ${voldid} (esperado AI_CPU_OS_*)"
    fi
  fi
  log_info "Tamanho: $(du -h "$INPUT" | awk '{print $1}')"
  log_info "SHA256:  $(sha256sum "$INPUT" | awk '{print $1}')"
else
  skip "Volume ID/SHA256 só são checáveis com --iso"
fi

# ---------------------------------------------------------------------------
# 8. Bit de execução (só no modo --dir: dentro da ISO o xorriso não expõe isso)
# ---------------------------------------------------------------------------
section "Permissões"
if [[ "$MODE" == "dir" ]]; then
  for f in build.sh detect-hardware.sh llama-build.sh families/resolve.sh \
           mods/apply.sh preseed/late-command.sh preseed/firstboot.sh; do
    if [[ -x "${INPUT}/ai-cpu-os/${f}" || -x "${INPUT}/${f}" ]]; then
      pass "executável: ${f}"
    else
      fail "sem bit de execução: ${f}"
    fi
  done
else
  skip "bit de execução não é verificável via xorriso (use --dir após extrair)"
fi

# ---------------------------------------------------------------------------
# Resumo
# ---------------------------------------------------------------------------
printf '\n%b=== RESUMO (%s / %s) ===%b\n' "$C_BOLD" "$DISTRO" "$MODE" "$C_RESET"
printf '  PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"

if [[ $FAIL -gt 0 ]]; then
  log_error "Verificação FALHOU: ${FAIL} problema(s). A ISO pode não instalar sozinha."
  exit 1
fi
log_info "Verificação OK. Isto NÃO prova que a ISO boota: só confirma o conteúdo."
log_info "Próximo passo (obrigatório): bootar em VM — bash iso/test-vm.sh --iso <iso>"
exit 0
