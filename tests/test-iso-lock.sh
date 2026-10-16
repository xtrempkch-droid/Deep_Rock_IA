#!/usr/bin/env bash
#
# tests/test-iso-lock.sh — prova a TRAVA DE INSTÂNCIA ÚNICA do gerador de ISO
# -----------------------------------------------------------------------------
# O que este teste protege:
#
#   Dois builds do `iso/build-iso.sh` ao mesmo tempo no mesmo `--work-dir`
#   brigam pelos arquivos `.part` (o modelo de ~1,1 GB e a fonte do llama.cpp).
#   Um build renomeia o `.part` para o nome final enquanto o outro ainda
#   escreve nele pelo fd aberto — e o segundo morre com
#
#       mv: cannot stat '…/iso/work/models/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf.part':
#       No such file or directory
#
#   O arquivo NUNCA esteve ausente: ele foi RENOMEADO pelo outro build. Foi
#   exatamente este erro que apareceu numa sessão real, e o sintoma que veio
#   junto ("a máquina travou") casa: dois downloads de 1,1 GB + dois builds
#   pesados na mesma máquina modesta.
#
# Por que um teste separado: o comportamento depende de um `flock` de verdade
# (dois processos), e não de uma função pura. Sem este teste, a trava poderia
# ser removida numa refatoração sem nada reclamar.
#
# O que ele NÃO prova: que a ISO fica correta. Ele nunca gera ISO — só tenta
# os caminhos que a trava RECUSA (e um dry-run, que ela deve DEIXAR passar).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TEST_DIR"

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && printf '  ok   %s\n' "$*"; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

SCRIPT="iso/build-iso.sh"
[[ -f "$SCRIPT" ]] || { echo "FALHOU: $SCRIPT não existe" >&2; exit 1; }

WORK="$(mktemp -d)"
LOCK_HELD_PID=""
cleanup() {
  # Solta a trava se ainda estivermos segurando (mata o processo que a segura).
  if [[ -n "$LOCK_HELD_PID" ]]; then
    kill "$LOCK_HELD_PID" 2>/dev/null || true
    wait "$LOCK_HELD_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0) Sanidade: o código tem mesmo a trava?
# ---------------------------------------------------------------------------
if grep -q '^acquire_build_lock()' "$SCRIPT"; then
  ok "acquire_build_lock() existe no gerador"
else
  bad "acquire_build_lock() desapareceu do gerador (a proteção foi removida)"
fi
if grep -q '^download_to()' "$SCRIPT"; then
  ok "download_to() existe (o download não confia só no exit do curl)"
else
  bad "download_to() desapareceu (o 'mv: cannot stat' pode voltar)"
fi
# A verificação do `.part` ANTES do mv é o coração do conserto: sem ela, um
# curl que "deu certo" mas não deixou arquivo vira erro críptico.
if grep -q 'if \[\[ ! -s "${dest}.part" \]\]' "$SCRIPT"; then
  ok "download_to() confere que o .part existe e não está vazio antes do mv"
else
  bad "download_to() voltou a renomear o .part sem conferir que ele existe"
fi

# ---------------------------------------------------------------------------
# 1) Sem ninguém segurando a trava: o dry-run passa (não trava dry-run)
# ---------------------------------------------------------------------------
if bash "$SCRIPT" --dry-run --yes --disk /dev/vda \
      --work-dir "$WORK" >/dev/null 2>&1; then
  ok "dry-run passa sem trava (dry-run não escreve, não precisa travar)"
else
  bad "dry-run foi recusado — a trava não deve valer em --dry-run"
fi

# ---------------------------------------------------------------------------
# 2) Com a trava tomada: um build REAL é recusado com mensagem que explica
# ---------------------------------------------------------------------------
# Seguramos a trava como o build faria (fd 9 + flock -n), num processo à parte
# que fica vivo até o fim do teste.
bash -c '
  exec 9>"'"$TEST_DIR"'/iso/.build-iso.lock" || exit 1
  flock -n 9 || exit 1
  echo "$$" >&9
  sleep 30
' &
LOCK_HELD_PID=$!
# Dá tempo do processo acima tomar a trava (senão o teste vira uma corrida).
for _ in $(seq 1 50); do
  if flock -n "$TEST_DIR/iso/.build-iso.lock" -c true 2>/dev/null; then
    sleep 0.1
  else
    break
  fi
done

set +e
out="$(bash "$SCRIPT" --yes --disk /dev/vda --work-dir "$WORK" \
        --out "$WORK/x.iso" 2>&1)"
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  ok "com a trava ocupada, o build é RECUSADO (rc=${rc})"
else
  bad "o build rodou mesmo com a trava ocupada (rc=0) — concorrência sem proteção"
fi
if grep -q 'Já existe um build da ISO em andamento' <<<"$out"; then
  ok "a recusa DIZ que já existe um build (em vez de erro críptico)"
else
  bad "a recusa não explicou o motivo (saída: $(head -c 200 <<<"$out"))"
fi
# A mensagem tem de mandar o usuário esperar — não basta dizer "erro".
if grep -q 'Espere o outro terminar' <<<"$out"; then
  ok "a recusa diz o que fazer (esperar o outro terminar)"
else
  bad "a recusa não diz o que fazer"
fi
# E o mais importante: um 'mv: cannot stat' de VERDADE não deve aparecer.
#
# CUIDADO (armadilha já pisada 3×): a NOSSA mensagem de erro CITA o texto
# "mv: cannot stat … .part" para o usuário reconhecer o sintoma. Procurar só
# por "cannot stat" casaria com a explicação e reprovaria uma árvore correta.
# O erro real do `mv` sempre traz "No such file or directory" — a nossa
# mensagem, não. É esse o discriminador.
if grep -q 'No such file or directory' <<<"$out"; then
  bad "erro real do mv reapareceu ('No such file or directory') — o sintoma original voltou"
else
  ok "nenhum erro real de mv (o sintoma original não acontece)"
fi

# ---------------------------------------------------------------------------
# 3) Mesmo com a trava ocupada, o dry-run continua passando
# ---------------------------------------------------------------------------
if bash "$SCRIPT" --dry-run --yes --disk /dev/vda \
      --work-dir "$WORK" >/dev/null 2>&1; then
  ok "dry-run passa mesmo com um build rodando (preview não é bloqueado)"
else
  bad "o dry-run foi bloqueado por um build em andamento"
fi

# ---------------------------------------------------------------------------
# 4) A trava é liberada ao terminar (não deixa o próximo build preso)
# ---------------------------------------------------------------------------
kill "$LOCK_HELD_PID" 2>/dev/null || true
wait "$LOCK_HELD_PID" 2>/dev/null || true
LOCK_HELD_PID=""
for _ in $(seq 1 50); do
  if flock -n "$TEST_DIR/iso/.build-iso.lock" -c true 2>/dev/null; then
    break
  fi
  sleep 0.1
done
set +e
out2="$(bash "$SCRIPT" --yes --disk /dev/vda --work-dir "$WORK" \
         --out "$WORK/x.iso" --iso none 2>&1 | head -60)"
set -e
# O build real vai falhar por falta de xorriso/ISO — o que importa é que ele
# PASSOU da trava (não recebeu "Já existe um build").
if grep -q 'Já existe um build da ISO em andamento' <<<"$out2"; then
  bad "a trava continuou presa depois do build anterior terminar"
else
  ok "a trava é liberada quando o build termina (o próximo passa)"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "iso-lock: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "iso-lock: PASS=${PASS} FAIL=${FAIL}"
exit 1
