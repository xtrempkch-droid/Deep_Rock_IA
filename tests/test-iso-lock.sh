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
# COMO ELE SEGURA A TRAVA (e por que assim) — armadilha paga caro:
#
#   O detentor é um `bash -c` que abre o fd 9 no arquivo de trava e fica vivo
#   até ser morto. O `sleep` filho leva `9>&-`: ele NÃO herda o fd da trava, e
#   quem a segura é o próprio `bash` (o `wait` é builtin, então o bash não
#   "troca de identidade" pelo último comando).
#
#   Isso importa porque a otimização em que o `bash -c` faz `exec` do último
#   comando NÃO é garantida — basta um `BASH_ENV` que defina um `trap` para o
#   bash desistir dela. Quando isso acontece o `sleep` vira um FILHO que herda
#   o fd 9: `kill` no detentor mata só o pai, o filho continua segurando a
#   trava e este teste REPROVA com o gerador CORRETO. Foi o `validate` #57
#   vermelho ("Process completed with exit code 2", com o passo levando ~6 s —
#   os 5 s do laço de espera que estourava). Com `9>&-` + `wait`, matar o
#   detentor solta a trava em QUALQUER ambiente. Reproduza o modo de falha:
#
#       printf 'trap ":" EXIT\n' > /tmp/besen.sh
#       BASH_ENV=/tmp/besen.sh bash tests/test-iso-lock.sh   # sem o 9>&-: FALHA
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
ok() {
  PASS=$((PASS + 1))
  if [[ $VERBOSE -eq 1 ]]; then printf '  ok   %s\n' "$*"; fi
  return 0
}
# Todo FALHOU também vira ANOTAÇÃO do GitHub. O log do job é 403 para quem não
# tem token; a anotação é pública e aparece no resumo do check — é o único
# canal que deixa diagnosticar um CI vermelho sem acesso ao log (docs/CI.md).
bad() {
  FAIL=$((FAIL + 1))
  printf '  FALHOU %s\n' "$*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" || -n "${CI:-}" ]]; then
    printf '::error::test-iso-lock: %s\n' "$*"
  fi
  return 0
}

SCRIPT="iso/build-iso.sh"
LOCKFILE="${TEST_DIR}/iso/.build-iso.lock"
if [[ ! -f "$SCRIPT" ]]; then
  echo "FALHOU: $SCRIPT não existe" >&2
  exit 1
fi

# Nenhum build real do teste pode pendurar o job do CI (rede/disco): cada um
# leva um teto de tempo. Sem `timeout` no PATH, roda sem ele.
TMO=()
if command -v timeout >/dev/null 2>&1; then TMO=(timeout 180); fi

WORK="$(mktemp -d)"
LOCK_HELD_PID=""
cleanup() {
  # Solta a trava se ainda estivermos segurando: mata o DETENTOR (o fd 9 é só
  # dele — nenhum filho o herdou), então a trava cai junto.
  if [[ -n "$LOCK_HELD_PID" ]]; then
    kill "$LOCK_HELD_PID" 2>/dev/null || true
    wait "$LOCK_HELD_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Esperas e diagnóstico
# ---------------------------------------------------------------------------
# Sem `!` e sem `cmd && return` como última instrução: o `!` é IGNORADO pelo
# `set -e` e o `&&` faz a função devolver 1 — duas armadilhas já pisadas aqui.
wait_lock_free() {
  local i
  for ((i = 0; i < 150; i++)); do
    if flock -n "$LOCKFILE" -c true 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}
wait_lock_held() {
  local i
  for ((i = 0; i < 150; i++)); do
    if flock -n "$LOCKFILE" -c true 2>/dev/null; then sleep 0.1; else return 0; fi
  done
  return 1
}
# Quem ainda tem a trava aberta — varredura de /proc (sem lsof/fuser). Olha
# TODOS os fds, não só o 9: o `flock` da linha de comando usa fd próprio, e um
# detentor que perdemos de vista não ajuda em nada no diagnóstico.
# Só é chamado para DIAGNOSTICAR uma espera que estourou.
lock_fd_holders() {
  local p f alvo
  for p in /proc/[0-9]*; do
    for f in "$p"/fd/*; do
      alvo="$(readlink "$f" 2>/dev/null)" || alvo=""
      if [[ "$alvo" == "$LOCKFILE" ]]; then
        printf '%s:%s ' "${p#/proc/}" "$(basename "$f")"
      fi
    done
  done
}
lock_owner_note() {
  printf 'dono registrado no arquivo: %s · processos com a trava aberta: %s' \
    "$(cat "$LOCKFILE" 2>/dev/null || printf '?')" "$(lock_fd_holders)"
}

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
# 0.1) Pré-voo: a trava PRECISA estar livre quando começamos
# ---------------------------------------------------------------------------
# Se outro processo (um build de verdade, ou um teste que morreu sem soltar)
# já segura a trava, tudo abaixo vira falso positivo/negativo — e o sintoma
# seria justamente "a trava continuou presa" lá na frente. Melhor dizer na
# hora, mostrando QUEM está segurando.
if ! ( exec 9>>"$LOCKFILE" ) 2>/dev/null; then
  bad "não consigo abrir ${LOCKFILE} para a trava (permissão em iso/?)"
elif wait_lock_free; then
  ok "a trava está livre antes do teste (nenhum build rodando)"
else
  bad "a trava ${LOCKFILE} JÁ estava presa antes do teste — $(lock_owner_note)"
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
# que fica vivo até ser morto. O `9>&-` no filho é o que garante que matar o
# detentor SOLTA a trava (ver o cabeçalho deste arquivo).
# Seguramos a trava como o build faria (fd 9), num processo à parte que fica
# vivo até ser morto. Duas sutilezas que já custaram um vermelho:
#
#   * `flock -w 20` (esperando) e não `-n`: quem QUER a trava não pode perder a
#     corrida para as SONDAS do próprio teste (`flock -c true`, que também
#     precisam pegá-la por um instante). Com `-n`, o detentor morria na largada
#     em ~1 de cada 3 execuções — um teste flaky, pior que um teste ausente.
#   * `sleep 300 9>&-` + `wait`: o filho NÃO herda o fd 9, e quem segura a
#     trava é o próprio `bash` (o `wait` é builtin, então não há "troca de
#     identidade" pelo último comando). Assim matar o detentor solta a trava
#     mesmo onde o bash não faz `exec` do último comando — basta um `BASH_ENV`
#     com `trap` para desligar a otimização.
bash -c '
  set -u
  exec 9>"$1" || exit 1
  flock -w 20 9 || exit 1
  printf "%s\n" "$$" >&9
  sleep 300 9>&- &
  filho=$!
  trap "kill \"$filho\" 2>/dev/null; exit 0" TERM INT
  wait "$filho"
' _ "$LOCKFILE" &
LOCK_HELD_PID=$!

if wait_lock_held; then
  ok "o processo de teste tomou a trava (o build tem de ser recusado agora)"
else
  bad "não consegui tomar a trava para o teste ($(lock_owner_note))"
fi

# Os payloads vão em `none` de propósito: um build real aqui NUNCA deve tocar
# a rede (sem isso, uma falha na trava faria o CI baixar 2,6 GB de ISO).
set +e
out="$("${TMO[@]}" bash "$SCRIPT" --yes --disk /dev/vda --work-dir "$WORK" \
        --out "$WORK/x.iso" --iso none --iso-model none --iso-source none \
        --iso-repo none --no-verify 2>&1)"
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

if wait_lock_free; then
  ok "matar o detentor libera a trava (nenhum filho segura o fd)"
else
  bad "a trava continuou presa depois que o detentor morreu — $(lock_owner_note)"
fi

set +e
out2="$("${TMO[@]}" bash "$SCRIPT" --yes --disk /dev/vda --work-dir "$WORK" \
         --out "$WORK/x.iso" --iso none --iso-model none --iso-source none \
         --iso-repo none --no-verify 2>&1 | head -60)"
set -e
# O build real vai falhar por falta de xorriso/ISO — o que importa é que ele
# PASSOU da trava (não recebeu "Já existe um build").
if grep -q 'Já existe um build da ISO em andamento' <<<"$out2"; then
  bad "o próximo build recebeu 'Já existe um build' — a trava não foi liberada"
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
