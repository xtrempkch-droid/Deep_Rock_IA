#!/usr/bin/env bash
#
# tests/test-check-iso.sh — prova a conferência de uma ISO BAIXADA
# -----------------------------------------------------------------------------
# Exercita o `iso/check-iso.sh`, que existe para quem **não tem xorriso** (a
# máquina de desenvolvimento é assim): ele confere um arquivo baixado usando só
# `dd`/`od`/`sha256sum`.
#
# As fixtures são construídas byte a byte (via `python3`) para exercitar cada
# verificação de forma independente — inclusive os modos de falha reais:
#
#   - o navegador entrega o ARTIFACT (um .zip) em vez do .iso;
#   - download truncado;
#   - download corrompido (SHA256 divergente);
#   - uma ISO de outra origem (Volume ID diferente);
#   - ausência da assinatura de boot.
#
# Nenhum caso toca rede, dispositivo, root ou xorriso.
#
# Uso: bash tests/test-check-iso.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly CHECK="${TEST_ROOT}/iso/check-iso.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# --- Construtor de fixtures -------------------------------------------------
# mk_iso <arquivo> <volume-id> <mbr:sim|nao> <setor-16:sim|nao>
mk_iso() {
  python3 - "$@" <<'PY'
import sys, pathlib
dest, volid, mbr, pvd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# 2 MB: grande o bastante para caber o setor 16 sem ser um arquivo gigante.
size = 2 * 1024 * 1024
buf = bytearray(size)

if mbr == "sim":
    # Assinatura de MBR: 0x55AA nos dois últimos bytes do setor 0.
    buf[510] = 0x55
    buf[511] = 0xAA

if pvd == "sim":
    # Primary Volume Descriptor no LBA 16 (setor de 2048).
    base = 16 * 2048
    buf[base] = 1                      # tipo = PVD
    buf[base + 1:base + 6] = b"CD001"  # identificador padrão
    buf[base + 6] = 1                  # versão
    # Volume Identifier: offset 40 do PVD, 32 bytes, preenchido com espaços.
    vid = volid.encode()[:32].ljust(32, b" ")
    buf[base + 40:base + 72] = vid

pathlib.Path(dest).write_bytes(bytes(buf))
PY
}

# run_check <args...> -> imprime saída; devolve o código em CHECK_RC
CHECK_RC=0
run_check() {
  set +e
  CHECK_OUT="$(bash "$CHECK" "$@" 2>&1)"
  CHECK_RC=$?
  set -e
}

echo "Conferência de ISO baixada (sem xorriso)"

# ---------------------------------------------------------------------------
# 1) ISO boa: tudo passa
# ---------------------------------------------------------------------------
mk_iso "$WORK/boa.iso" "AI_CPU_OS_UBUNTU_INFERENCE" sim sim
run_check --iso "$WORK/boa.iso" --min-size 1
[[ $CHECK_RC -eq 0 ]] && ok "ISO válida: exit 0" || { bad "ISO válida: exit $CHECK_RC"; echo "$CHECK_OUT" | tail -6 | sed 's/^/        /'; }
case "$CHECK_OUT" in
  *"CD001"*) ok "detecta a assinatura ISO 9660" ;;
  *) bad "não detectou a assinatura ISO 9660" ;;
esac
case "$CHECK_OUT" in
  *AI_CPU_OS_UBUNTU_INFERENCE*) ok "mostra o Volume ID" ;;
  *) bad "não mostrou o Volume ID" ;;
esac
case "$CHECK_OUT" in
  *"0x55AA"*) ok "detecta a assinatura de boot" ;;
  *) bad "não detectou a assinatura de boot" ;;
esac

# ---------------------------------------------------------------------------
# 2) SHA256: correto passa, errado reprova, arquivo ao lado é lido sozinho
# ---------------------------------------------------------------------------
good_sha="$(sha256sum "$WORK/boa.iso" | awk '{print $1}')"
run_check --iso "$WORK/boa.iso" --min-size 1 --sha256 "$good_sha"
[[ $CHECK_RC -eq 0 ]] && ok "SHA256 correto: exit 0" || bad "SHA256 correto: exit $CHECK_RC"

run_check --iso "$WORK/boa.iso" --min-size 1 --sha256 "0000000000000000000000000000000000000000000000000000000000000000"
if [[ $CHECK_RC -ne 0 ]] && printf '%s' "$CHECK_OUT" | grep -q "divergente"; then
  ok "SHA256 divergente: reprova (download corrompido)"
else
  bad "SHA256 divergente NÃO reprovou (exit $CHECK_RC)"
fi

# Download simulado: .iso + .iso.sha256 lado a lado (é como o CI publica).
cp "$WORK/boa.iso" "$WORK/com-sha.iso"
printf '%s  com-sha.iso\n' "$good_sha" > "$WORK/com-sha.iso.sha256"
run_check --iso "$WORK/com-sha.iso" --min-size 1
[[ $CHECK_RC -eq 0 ]] && ok "lê o .sha256 ao lado do arquivo" || bad "não usou o .sha256 ao lado (exit $CHECK_RC)"

# Corrompe um byte: o SHA256 do vizinho tem de denunciar.
cp "$WORK/com-sha.iso" "$WORK/corrompida.iso"
printf 'X' | dd of="$WORK/corrompida.iso" bs=1 seek=4000 conv=notrunc status=none
cp "$WORK/com-sha.iso.sha256" "$WORK/corrompida.iso.sha256"
run_check --iso "$WORK/corrompida.iso" --min-size 1
[[ $CHECK_RC -ne 0 ]] && ok "1 byte corrompido: reprova" || bad "1 byte corrompido NÃO reprovou"

# ---------------------------------------------------------------------------
# 3) O modo de falha mais comum: o navegador entrega o ZIP (artifact)
# ---------------------------------------------------------------------------
python3 -c "import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b'PK\x03\x04' + bytes(2000))" "$WORK/artifact.zip"
run_check --iso "$WORK/artifact.zip" --min-size 0
if [[ $CHECK_RC -ne 0 ]] && printf '%s' "$CHECK_OUT" | grep -q "não é uma ISO 9660"; then
  ok "zip renomeado: reprova e explica o motivo"
else
  bad "zip renomeado NÃO reprovou (exit $CHECK_RC)"
fi
case "$CHECK_OUT" in
  *"ARTIFACT"*|*"Descompacte"*) ok "a mensagem diz o que fazer (descompactar)" ;;
  *) bad "a mensagem não orienta o usuário" ;;
esac

# ---------------------------------------------------------------------------
# 4) Volume ID: de outra origem reprova, mas --allow-any-volid libera
# ---------------------------------------------------------------------------
mk_iso "$WORK/outra.iso" "OUTRA_DISTRO_QUALQUER" sim sim
run_check --iso "$WORK/outra.iso" --min-size 1
if [[ $CHECK_RC -ne 0 ]] && printf '%s' "$CHECK_OUT" | grep -q "Volume ID inesperado"; then
  ok "Volume ID de outra origem: reprova"
else
  bad "Volume ID de outra origem NÃO reprovou (exit $CHECK_RC)"
fi
run_check --iso "$WORK/outra.iso" --min-size 1 --allow-any-volid
[[ $CHECK_RC -eq 0 ]] && ok "--allow-any-volid: aceita outra origem" || bad "--allow-any-volid reprovou (exit $CHECK_RC)"

# ---------------------------------------------------------------------------
# 5) Download truncado: pego pelo tamanho mínimo
# ---------------------------------------------------------------------------
run_check --iso "$WORK/boa.iso" --min-size 100
if [[ $CHECK_RC -ne 0 ]] && printf '%s' "$CHECK_OUT" | grep -q "menor que o mínimo"; then
  ok "arquivo pequeno demais: reprova (download truncado)"
else
  bad "tamanho mínimo não foi aplicado (exit $CHECK_RC)"
fi

# ---------------------------------------------------------------------------
# 6) Sem assinatura de boot: AVISA mas não reprova (UEFI ainda pode bootar)
# ---------------------------------------------------------------------------
mk_iso "$WORK/sem-mbr.iso" "AI_CPU_OS_UBUNTU_AUTO" nao sim
run_check --iso "$WORK/sem-mbr.iso" --min-size 1
[[ $CHECK_RC -eq 0 ]] && ok "sem MBR: não reprova (é WARN, não FAIL)" || bad "sem MBR reprovou (exit $CHECK_RC)"
case "$CHECK_OUT" in
  *"[WARN]"*) ok "sem MBR: avisa" ;;
  *) bad "sem MBR: não avisou" ;;
esac

# ---------------------------------------------------------------------------
# 7) Sem SHA256 disponível: avisa (não dá para provar integridade), não reprova
# ---------------------------------------------------------------------------
mk_iso "$WORK/sem-sha.iso" "AI_CPU_OS_UBUNTU_AUTO" sim sim
run_check --iso "$WORK/sem-sha.iso" --min-size 1
[[ $CHECK_RC -eq 0 ]] && ok "sem SHA256: não reprova" || bad "sem SHA256 reprovou (exit $CHECK_RC)"
case "$CHECK_OUT" in
  *"nenhum SHA256"*) ok "sem SHA256: avisa que não prova integridade" ;;
  *) bad "sem SHA256: não avisou" ;;
esac

# ---------------------------------------------------------------------------
# 8) Uso errado: exit 2 (diferente de "a ISO está com problema")
# ---------------------------------------------------------------------------
run_check --iso "$WORK/nao-existe.iso"
[[ $CHECK_RC -eq 2 ]] && ok "arquivo inexistente: exit 2 (erro de uso)" || bad "arquivo inexistente deu exit $CHECK_RC"
run_check
[[ $CHECK_RC -eq 2 ]] && ok "sem --iso: exit 2 (erro de uso)" || bad "sem --iso deu exit $CHECK_RC"
run_check --help
[[ $CHECK_RC -eq 0 ]] && ok "--help: exit 0" || bad "--help deu exit $CHECK_RC"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "check-iso: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "check-iso: PASS=${PASS} FAIL=${FAIL}"
exit 1
