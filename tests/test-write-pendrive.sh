#!/usr/bin/env bash
#
# tests/test-write-pendrive.sh — prova as TRAVAS de segurança do pendrive
# -----------------------------------------------------------------------------
# `iso/write-pendrive.sh` é o passo mais perigoso do projeto: `dd` num
# dispositivo apaga tudo, sem desfazer. As travas existem para impedir o pior
# caso (apontar para o disco errado), então elas precisam de TESTE — uma trava
# que não reprova não protege ninguém (lição das sessões #19/#20).
#
# O teste roda SEM root, SEM pendrive e SEM escrever em nenhum dispositivo. Três
# níveis, do mais real ao mais simulado:
#
#   A) Travas contra o ambiente REAL desta máquina: o disco que contém `/` tem
#      de ser recusado, e o DVD (`RM=1` mas `TYPE=rom`) também. Nada de stub —
#      é o `lsblk`/`findmnt` de verdade respondendo sobre os discos de verdade.
#   B) Travas com as costuras substituídas (disco removível fictício, partição,
#      montado, ISO que não cabe, alvo suspeitamente grande).
#   C) Gravação + VERIFICAÇÃO de ponta a ponta com `dd` e `cmp` REAIS, mas
#      apontando para um ARQUIVO comum em vez de um device — inclusive o caso
#      negativo (conteúdo corrompido tem de fazer a verificação FALHAR).
#
# As "costuras" são funções (dev_is_block_device, dev_is_whole_disk, dev_field,
# dev_size_bytes, root_disk_name, dev_is_mounted, dev_is_removable) justamente
# para poderem ser substituídas aqui depois do `source`.
#
# Uso: bash tests/test-write-pendrive.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly PEND="${TEST_ROOT}/iso/write-pendrive.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

# Espera que `validate_target` RECUSE (rc != 0) e que a mensagem contenha <msg>.
# Ele escreve no stderr, então capturamos os dois.
recusa() {
  local desc="$1" dev="$2" msg="${3:-}" out rc=0
  out="$(validate_target "$dev" 2>&1)" || rc=$?
  if (( rc == 0 )); then
    bad "${desc}: NÃO recusou (deveria)"
    return 0
  fi
  if [[ -n "$msg" ]] && ! printf '%s' "$out" | grep -qi "$msg"; then
    bad "${desc}: recusou, mas a mensagem não explica (esperava /${msg}/)"
    printf '%s\n' "$out" | head -3 | sed 's/^/        /'
    return 0
  fi
  ok "recusa: ${desc}"
}

aceita() {
  local desc="$1" dev="$2" out rc=0
  out="$(validate_target "$dev" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    bad "${desc}: recusou um alvo que deveria ser aceito"
    printf '%s\n' "$out" | head -4 | sed 's/^/        /'
    return 0
  fi
  ok "aceita: ${desc}"
}

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=/dev/null
source "$PEND"

# Tamanhos usados nas travas (o script lê estas variáveis globais).
ISO_SIZE_BYTES=$(( 400 * 1024 * 1024 ))   # ISO fictícia de 400 MB
ISO_SIZE_MB=400

echo "Travas do gravador de pendrive (sem root, sem device, sem escrita)"

# ===========================================================================
# A) Contra o ambiente REAL (sem stub)
# ===========================================================================
echo
echo "A) Ambiente real — o disco do sistema e um DVD têm de ser recusados"

root_disk="$(root_disk_name)"
if [[ -z "$root_disk" ]]; then
  ok "ambiente sem / isolado (nada a testar aqui)"
else
  # Esta é a trava nº 1: apontar para o disco que contém / destruiria a máquina.
  recusa "disco da raiz (/dev/${root_disk})" "/dev/${root_disk}" "sistema em execução"
fi

# O DVD desta máquina: RM=1 (removível!) mas TYPE=rom. Sem a checagem de TYPE,
# ele passaria como alvo válido — e gravar num DVD não faz sentido nenhum.
if [[ -b /dev/sr0 ]]; then
  recusa "drive de DVD (/dev/sr0, RM=1 mas TYPE=rom)" "/dev/sr0" "não é um DISCO inteiro"
else
  ok "sem /dev/sr0 nesta máquina (pulado)"
fi

recusa "dispositivo inexistente" "/dev/sdzz" "não é um dispositivo de bloco"
recusa "caminho fora de /dev" "/tmp/qualquer" "/dev/"

# ===========================================================================
# B) Com as costuras substituídas
# ===========================================================================
echo
echo "B) Costuras simuladas (disco removível fictício)"

# A partir daqui: /dev/fake-disk é um disco removível de 8 GB, limpo.
dev_is_block_device() { [[ "$1" == "/dev/fake-disk" ]]; }
dev_is_whole_disk()   { [[ "$1" == "/dev/fake-disk" ]]; }
dev_field() {
  case "$2" in
    TYPE) [[ "$1" == "/dev/fake-disk" ]] && echo disk ;;
    RM)   echo 1 ;;
    TRAN) echo usb ;;
  esac
}
dev_size_bytes() { echo $(( 8 * 1024 * 1024 * 1024 )); }
dev_is_mounted() { return 1; }
# A raiz fica num disco DIFERENTE do alvo (senão toda gravação seria recusada).
root_disk_name() { echo "algum-outro"; }

aceita "pendrive USB de 8 GB, limpo" "/dev/fake-disk"

# Disco NÃO removível: recusa, a menos que --allow-internal.
dev_is_removable() { return 1; }
if (( ALLOW_INTERNAL == 0 )); then
  recusa "disco interno sem --allow-internal" "/dev/fake-disk" "NÃO é removível"
fi
ALLOW_INTERNAL=1
aceita "disco interno COM --allow-internal" "/dev/fake-disk"
ALLOW_INTERNAL=0
dev_is_removable() { return 0; }

# Partição em vez de disco.
dev_is_whole_disk() { return 1; }
dev_field() { case "$2" in TYPE) echo part ;; esac; }
recusa "partição em vez do disco" "/dev/fake-disk" "DISCO inteiro"
dev_is_whole_disk() { [[ "$1" == "/dev/fake-disk" ]]; }
dev_field() { case "$2" in TYPE) echo disk ;; RM) echo 1 ;; TRAN) echo usb ;; esac; }

# Montado: gravar com o sistema de arquivos EM USO corromperia dados.
dev_is_mounted() { return 0; }
recusa "alvo montado" "/dev/fake-disk" "MONTADO"
dev_is_mounted() { return 1; }

# ISO que não cabe.
dev_size_bytes() { echo $(( 100 * 1024 * 1024 )); }   # 100 MB < 400 MB da ISO
recusa "ISO maior que o pendrive" "/dev/fake-disk" "NÃO CABE"
dev_size_bytes() { echo $(( 8 * 1024 * 1024 * 1024 )); }

# Alvo suspeitosamente maior (proporção): AVISA mas NÃO recusa — pode ser um
# pendrive grande de verdade.
dev_size_bytes() { echo $(( 64 * 1024 * 1024 * 1024 )); }   # 64 GB / 400 MB = 163x
if validate_target "/dev/fake-disk" >/dev/null 2>&1; then
  ok "proporção suspeita: avisa mas não bloqueia (correto)"
else
  bad "proporção suspeita: bloqueou (deveria só avisar)"
fi

# ===========================================================================
# C) Gravação + verificação de ponta a ponta (dd e cmp REAIS)
# ===========================================================================
echo
echo "C) Gravação e verificação de ponta a ponta (dd/cmp reais, alvo = arquivo)"

# "ISO" de 512 KiB com a assinatura ISO 9660 — is_iso9660 é checada de verdade.
fake_iso="${WORK}/teste.iso"
python3 -c "
import sys
size = 512 * 1024
data = bytearray(size)
data[32768:32773] = b'CD001'
open(sys.argv[1], 'wb').write(bytes(data))
" "$fake_iso"

# Um "dispositivo" que é arquivo comum: dd escreve e cmp lê de volta.
fake_dev="${WORK}/pendrive.img"
: > "$fake_dev"

ISO_PATH="$fake_iso"
ISO_SIZE_BYTES="$(stat -c %s "$fake_iso")"
# SC2034 é falso positivo aqui: este arquivo não LÊ ISO_SIZE_MB, mas as funções
# do iso/write-pendrive.sh (carregadas com `source` acima) usam nas mensagens de
# erro — e o shellcheck analisa só este arquivo, sem ver o corpo do outro.
# shellcheck disable=SC2034
ISO_SIZE_MB=$(( ISO_SIZE_BYTES / 1024 / 1024 ))

if is_iso9660 "$fake_iso"; then
  ok "detecta a assinatura ISO 9660 (CD001)"
else
  bad "não reconheceu uma ISO válida"
fi

bad_iso="${WORK}/nao-e-iso.bin"
head -c 4096 /dev/zero > "$bad_iso"
if is_iso9660 "$bad_iso"; then
  bad "aceitou um arquivo SEM a assinatura CD001"
else
  ok "recusa arquivo sem assinatura ISO 9660"
fi

# Espelha o que write_image + verify_image fazem, com os comandos REAIS.
dd if="$ISO_PATH" of="$fake_dev" bs=4M conv=fsync >/dev/null 2>&1
sync
if cmp -n "$ISO_SIZE_BYTES" "$ISO_PATH" "$fake_dev" >/dev/null 2>&1; then
  ok "gravação íntegra: a verificação (cmp -n) APROVA"
else
  bad "a verificação reprovou uma gravação correta"
fi

# Caso negativo: um byte trocado no "pendrive" tem de fazer a verificação falhar.
printf 'X' | dd of="$fake_dev" bs=1 seek=100000 conv=notrunc >/dev/null 2>&1
if cmp -n "$ISO_SIZE_BYTES" "$ISO_PATH" "$fake_dev" >/dev/null 2>&1; then
  bad "verificação APROVOU um dispositivo corrompido (trava inútil)"
else
  ok "verificação REPROVA dispositivo corrompido (1 byte trocado)"
fi

# E o tamanho de leitura é exato: bytes além do fim da imagem não entram no
# `cmp -n` (é por isso que não usamos sha256sum do dispositivo inteiro).
: > "$fake_dev"
dd if="$ISO_PATH" of="$fake_dev" bs=4M conv=fsync >/dev/null 2>&1
printf 'lixo-depois-da-imagem' >> "$fake_dev"    # pendrive maior que a ISO
if cmp -n "$ISO_SIZE_BYTES" "$ISO_PATH" "$fake_dev" >/dev/null 2>&1; then
  ok "lixo após a imagem não invalida a verificação (-n limita o escopo)"
else
  bad "a verificação ficou confusa com bytes além do fim da imagem"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "write-pendrive: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "write-pendrive: PASS=${PASS} FAIL=${FAIL}"
exit 1
