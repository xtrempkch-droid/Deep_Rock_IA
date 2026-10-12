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
  MODEL_LIST="$(xorriso -osirrox on -indev "$INPUT" -find /models -name '*.gguf' 2>/dev/null | grep '\.gguf$' || true)"
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
    if grep -qE '^#.*--allow-any-disk' "$PRESEED_LOCAL"; then
      pass "preseed sem disco fixo (--allow-any-disk explícito)"
    else
      fail "preseed sem disco fixo e sem o comentário de --allow-any-disk"
    fi
  fi
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
    if grep -q 'ai-cpu-os-auto' "$GRUB_LOCAL"; then
      pass "/boot/grub/grub.cfg tem a entrada 'ai-cpu-os-auto'"
    else
      fail "/boot/grub/grub.cfg SEM a entrada 'ai-cpu-os-auto' (não instalaria sozinho)"
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
  fi
fi

# ---------------------------------------------------------------------------
# 7. Metadados da mídia (só no modo --iso)
# ---------------------------------------------------------------------------
section "Metadados da mídia"
if [[ "$MODE" == "iso" ]]; then
  voldid="$(xorriso -indev "$INPUT" -pvd_info 2>/dev/null | awk -F': *' '/Volume id/{print $2}' | tr -d ' \r' || true)"
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
