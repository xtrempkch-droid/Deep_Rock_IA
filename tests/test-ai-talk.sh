#!/usr/bin/env bash
#
# tests/test-ai-talk.sh — prova o contrato do `ai-talk` SEM rede externa
# -----------------------------------------------------------------------------
# Sobe daemons reais em 127.0.0.1 (porta efêmera) com diretórios temporários e
# confere a SEMÂNTICA do docs/CHAT.md §6.7/§6.8 — não wall-clock rígido:
#
#   * send → ack; a mensagem chega no log do receptor com fsync;
#   * espaçamento de `min_interval_ms` por par (msg/ping);
#   * `ack`/`hello` NÃO são atrasados pelo throttle;
#   * fila cheia → exit 5 (nunca descarte silencioso);
#   * dedupe: `id` repetido não duplica no log e o ack é reenviado;
#   * assinatura inválida / peer desconhecido → rejeitados;
#   * `ECONNREFUSED` → exit 3 rápido (fail fast);
#   * check-config recusa chave frouxa e frota acima de 15 (ADR-005);
#   * `listen` entrega em < 2 s; `tail` lê o JSONL;
#   * somente biblioteca padrão (nenhum import externo).
#
# Sem root, sem rede externa, sem pip. Uso: bash tests/test-ai-talk.sh [-v]
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly TOOL="${TEST_ROOT}/talk/ai_talk.py"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok    $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d)"
readonly WORK
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

at() { python3 "$TOOL" --config "$1" "${@:2}"; }

free_ports() {
  python3 - <<'PY'
import socket
socks = []
ports = []
for _ in range(6):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    socks.append(sock)
    ports.append(sock.getsockname()[1])
for sock in socks:
    sock.close()
print(" ".join(str(p) for p in ports))
PY
}
read -r PA PB PC PD PE PF <<<"$(free_ports)"

# --- chaves ---------------------------------------------------------------
python3 - "$WORK" <<'PY'
import os, sys
work = sys.argv[1]
for name in ("keyA", "keyB", "keyC", "keyD", "keyE", "keyF", "keyWrong"):
    path = os.path.join(work, name)
    with open(path, "wb") as handle:
        handle.write(os.urandom(32).hex().encode())
    os.chmod(path, 0o640)
PY

make_config() { # nome porta campainha peers-json [chave] [extra-json]
  python3 - "$WORK" "$@" <<'PY'
import json, os, sys
work, name, port, peers_json = sys.argv[1:5]
key = sys.argv[5] if len(sys.argv) > 5 else "keyA"
extra = json.loads(sys.argv[6]) if len(sys.argv) > 6 else {}
cfg = {
    "node": name,
    "role": "inference" if name.endswith("A") else "builder",
    "listen": {"address": "127.0.0.1", "port": int(port)},
    "control_socket": os.path.join(work, f"{name}.sock"),
    "key_file": os.path.join(work, key),
    "peers": json.loads(peers_json),
    "log": {"path": os.path.join(work, f"{name}.jsonl")},
}
for section, values in extra.items():
    cfg.setdefault(section, {}).update(values)
path = os.path.join(work, f"{name}.json")
with open(path, "w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
print(path)
PY
}

start_daemon() { # config
  local cfg="$1"
  python3 "$TOOL" serve --config "$cfg" >"${cfg%.json}.out" 2>&1 &
  PIDS+=("$!")
  local sock
  sock="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["control_socket"])' "$cfg")"
  for _ in $(seq 1 100); do
    [[ -S "$sock" ]] && return 0
    sleep 0.05
  done
  echo "  FALHOU daemon não subiu: $cfg" >&2
  cat "${cfg%.json}.out" >&2
  return 1
}

peer() { printf '{"%s":{"addr":"127.0.0.1:%s"}}' "$1" "$2"; }
peer_key() { printf '{"%s":{"addr":"127.0.0.1:%s","key_file":"%s/%s"}}' "$1" "$2" "$WORK" "$3"; }

echo "== ai-talk: contrato (docs/CHAT.md §6.7/§6.8) =="

# --- par A/B: comportamento normal, espaçamento 400 ms --------------------
CFG_A="$(make_config A "$PA" "$(peer_key B "$PB" keyB)" keyA '{"timing":{"min_interval_ms":400}}')"
CFG_B="$(make_config B "$PB" "$(peer_key A "$PA" keyA)" keyB '{"timing":{"min_interval_ms":400}}')"
start_daemon "$CFG_A"
start_daemon "$CFG_B"

sleep 0.2
at "$CFG_A" status --json >"$WORK/status.json" 2>&1 || true
check "status lista o nó A"        "grep -q '\"node\": \"A\"' '$WORK/status.json'"
check "teto de 15 nós no status"   "grep -q '\"max_peers\": 15' '$WORK/status.json'"
check "fsync=always anunciado"     "grep -q '\"fsync\": \"always\"' '$WORK/status.json'"

# 1) entrega + ack + log no receptor
if at "$CFG_A" send B "primeira mensagem" >/dev/null 2>&1; then
  ok "send A→B devolve sucesso (ack)"
else
  bad "send A→B devolve sucesso (ack)"
fi
sleep 0.2
check "mensagem gravada no log do B" "grep -q 'primeira mensagem' '$WORK/B.jsonl'"
check "log guarda direction=in"      "grep -q '\"direction\":\"in\"' '$WORK/B.jsonl'"

# 2) espaçamento: 2 mensagens do mesmo par levam >= ~400 ms
python3 - "$CFG_A" "$WORK" <<'PY' >"$WORK/timing.json"
import json, socket, sys, time
cfg = json.load(open(sys.argv[1]))
path = cfg["control_socket"]

def call(req):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(path)
    sock.sendall(json.dumps(req).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    sock.close()
    return json.loads(data.decode())

t0 = time.time()
call({"cmd": "send", "to": "B", "body": "spacing-1", "wait": True})
call({"cmd": "send", "to": "B", "body": "spacing-2", "wait": True})
spacing_ms = (time.time() - t0) * 1000

# hello é isento (§6.7.2): passa mesmo com o par "quente"
t1 = time.time()
call({"cmd": "hello", "to": "B"})
hello_ms = (time.time() - t1) * 1000

# ping CONTA no throttle (§6.7.2): paga o intervalo
t2 = time.time()
call({"cmd": "ping", "to": "B"})
ping_ms = (time.time() - t2) * 1000

print(json.dumps({"spacing_ms": round(spacing_ms, 1),
                  "hello_ms": round(hello_ms, 1),
                  "ping_ms": round(ping_ms, 1)}))
PY
read -r SPACING HELLO PING < <(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["spacing_ms"], d["hello_ms"], d["ping_ms"])' "$WORK/timing.json")
if python3 -c "import sys; sys.exit(0 if float('$SPACING') >= 350 else 1)"; then
  ok "espaçamento respeitado (${SPACING} ms para 2 mensagens)"
else
  bad "espaçamento respeitado (${SPACING} ms para 2 mensagens)"
fi
if python3 -c "import sys; sys.exit(0 if float('$HELLO') < 300 else 1)"; then
  ok "hello (handshake) não paga o throttle (${HELLO} ms)"
else
  bad "hello (handshake) não paga o throttle (${HELLO} ms)"
fi
if python3 -c "import sys; sys.exit(0 if float('$PING') >= 300 else 1)"; then
  ok "ping conta no throttle, como o contrato manda (${PING} ms)"
else
  bad "ping conta no throttle, como o contrato manda (${PING} ms)"
fi

# 3) dedupe: o MESMO id duas vezes não duplica no log e o ack volta
TALK_ROOT="$TEST_ROOT" python3 - "$WORK" "$PB" <<'PY'
import importlib.util, json, os, socket, sys
work, port = sys.argv[1], int(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "ai_talk", os.path.join(os.environ["TALK_ROOT"], "talk", "ai_talk.py"))
talk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(talk)

key = talk.read_key(os.path.join(work, "keyA"))
env = {
    "v": 1, "id": "11111111-1111-4111-8111-111111111111",
    "ts": talk.now_ts(), "from": "A", "to": "B", "kind": "msg",
    "body": "duplicada", "reply_to": None, "sig": "",
}
env["sig"] = talk.sign(env, key)
acks = 0
for _ in range(2):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.sendall(talk.encode_line(env))
    line = talk.recv_line(sock, 16384)
    if line and json.loads(line.decode()).get("kind") == "ack":
        acks += 1
    sock.close()
sys.exit(0 if acks == 2 else 1)
PY
if [[ $? -eq 0 ]]; then ok "id repetido recebe ack nas duas vezes"; else bad "id repetido recebe ack nas duas vezes"; fi
sleep 0.2
COUNT="$(grep -c 'duplicada' "$WORK/B.jsonl" || true)"
check "id repetido NÃO duplica no log (ocorrências=$COUNT)" "[[ '$COUNT' == '1' ]]"

# 4) assinatura inválida é rejeitada (não grava, não responde ack)
if TALK_ROOT="$TEST_ROOT" python3 - "$WORK" "$PB" <<'PY'
import importlib.util, json, os, socket, sys
work, port = sys.argv[1], int(sys.argv[2])
spec = importlib.util.spec_from_file_location(
    "ai_talk", os.path.join(os.environ["TALK_ROOT"], "talk", "ai_talk.py"))
talk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(talk)

key = talk.read_key(os.path.join(work, "keyWrong"))
env = {
    "v": 1, "id": "22222222-2222-4222-8222-222222222222",
    "ts": talk.now_ts(), "from": "A", "to": "B", "kind": "msg",
    "body": "forjada", "reply_to": None, "sig": "",
}
env["sig"] = talk.sign(env, key)
sock = socket.create_connection(("127.0.0.1", port), timeout=5)
sock.sendall(talk.encode_line(env))
line = talk.recv_line(sock, 16384)
sock.close()
sys.exit(0 if not line else 1)
PY
then ok "assinatura inválida é rejeitada (sem ack)"; else bad "assinatura inválida é rejeitada (sem ack)"; fi
sleep 0.2
check "assinatura inválida não grava no log" "! grep -q 'forjada' '$WORK/B.jsonl'"

# 5) peer desconhecido e corpo grande
set +e
at "$CFG_A" send ghost "oi" >/dev/null 2>&1; rc_ghost=$?
at "$CFG_A" send B "$(python3 -c 'print("x"*9000)')" >/dev/null 2>&1; rc_big=$?
set -e
check "peer desconhecido → exit 4 (obtido $rc_ghost)" "[[ '$rc_ghost' -eq 4 ]]"
check "corpo > 8 KiB → exit 5 (obtido $rc_big)"       "[[ '$rc_big' -eq 5 ]]"

# --- par C/D: fila pequena (queue_max=2) e espaçamento 500 ms -------------
CFG_C="$(make_config C "$PC" "$(peer_key D "$PD" keyD)" keyC '{"timing":{"min_interval_ms":500,"queue_max":2}}')"
CFG_D="$(make_config D "$PD" "$(peer_key C "$PC" keyC)" keyD '{"timing":{"min_interval_ms":500,"queue_max":2}}')"
start_daemon "$CFG_C"
start_daemon "$CFG_D"
sleep 0.2

set +e
at "$CFG_C" send D "fila-1" --no-wait >/dev/null 2>&1; rc1=$?
at "$CFG_C" send D "fila-2" --no-wait >/dev/null 2>&1; rc2=$?
at "$CFG_C" send D "fila-3" --no-wait >/dev/null 2>&1; rc3=$?
at "$CFG_C" send D "fila-4" --no-wait >/dev/null 2>&1; rc4=$?
set -e
# queue_max=2 conta só quem AGUARDA: 1 em trânsito + 2 na fila = 3 aceitas.
check "fila: 1ª aceita, em trânsito (rc=$rc1)"     "[[ '$rc1' -eq 0 ]]"
check "fila: 2ª aceita, aguardando (rc=$rc2)"      "[[ '$rc2' -eq 0 ]]"
check "fila: 3ª aceita, aguardando (rc=$rc3)"      "[[ '$rc3' -eq 0 ]]"
check "fila: 4ª recusada com exit 5 (rc=$rc4)"     "[[ '$rc4' -eq 5 ]]"

# --- par E/F: peer offline (fail fast) e listen ---------------------------
OFFPORT="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"
CFG_E="$(make_config E "$PE" "$(python3 - <<PY
import json
print(json.dumps({
    "D": {"addr": "127.0.0.1:${OFFPORT}"},
    "F": {"addr": "127.0.0.1:${PF}", "key_file": "${WORK}/keyF"},
}))
PY
)" keyE '{"timing":{"max_attempts":3,"ack_timeout_ms":1000}}')"
CFG_F="$(make_config F "$PF" "$(peer_key E "$PE" keyE)" keyF)"
start_daemon "$CFG_E"
start_daemon "$CFG_F"
sleep 0.2

set +e
START="$(python3 -c 'import time;print(int(time.time()*1000))')"
at "$CFG_E" send D "ninguém em casa" >/dev/null 2>&1; rc_off=$?
END="$(python3 -c 'import time;print(int(time.time()*1000))')"
set -e
ELAPSED=$((END - START))
check "peer offline → exit 3 (obtido $rc_off)" "[[ '$rc_off' -eq 3 ]]"
check "peer offline falha rápido (< 2000 ms, obtido ${ELAPSED} ms)" "[[ '$ELAPSED' -lt 2000 ]]"

at "$CFG_F" listen --json >"$WORK/listen.out" 2>&1 &
LISTEN_PID=$!
PIDS+=("$LISTEN_PID")
sleep 0.3
at "$CFG_E" send F "ao vivo" >/dev/null 2>&1 || true
sleep 0.6
kill "$LISTEN_PID" 2>/dev/null || true
check "listen recebeu a mensagem" "grep -q 'ao vivo' '$WORK/listen.out'"

at "$CFG_F" tail -n 5 >"$WORK/tail.out" 2>&1 || true
check "tail lê o JSONL local" "grep -q 'ao vivo' '$WORK/tail.out'"

# --- validações de config -------------------------------------------------
LOOSE="$WORK/loose.key"
cp "$WORK/keyF" "$LOOSE"
chmod 644 "$LOOSE"
CFG_LOOSE="$(make_config L "$(python3 -c 'print(0)')" '{}' loose.key)"
set +e
at "$CFG_LOOSE" check-config >"$WORK/loose.out" 2>&1; rc_loose=$?
set -e
check "chave legível por outros → exit 2 (obtido $rc_loose)" "[[ '$rc_loose' -eq 2 ]]"

CFG_MANY="$(make_config M 7000 "$(python3 - <<'PY'
import json
print(json.dumps({f"n{i}": {"addr": f"127.0.0.1:{7400+i}"} for i in range(16)}))
PY
)" keyF)"
set +e
at "$CFG_MANY" check-config >"$WORK/many.out" 2>&1; rc_many=$?
set -e
check "16 peers excedem o teto de 15 → exit 2 (obtido $rc_many)" "[[ '$rc_many' -eq 2 ]]"
check "mensagem do teto cita ADR-005/relay" "grep -qi 'teto\\|relay' '$WORK/many.out'"

# --- CLI básico -----------------------------------------------------------
set +e
python3 "$TOOL" --version >/dev/null 2>&1; rc_ver=$?
python3 "$TOOL" --help >/dev/null 2>&1; rc_help=$?
python3 "$TOOL" send --help >/dev/null 2>&1; rc_sub=$?
set -e
check "--version funciona"  "[[ '$rc_ver' -eq 0 ]]"
check "--help funciona"     "[[ '$rc_help' -eq 0 ]]"
check "send --help funciona" "[[ '$rc_sub' -eq 0 ]]"

# --- somente stdlib -------------------------------------------------------
if python3 - "$TOOL" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
stdlib = set(getattr(sys, "stdlib_module_names", ()))
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        mods.update(alias.name.split(".")[0] for alias in node.names)
    elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
        mods.add(node.module.split(".")[0])
mods.discard("__future__")
ext = sorted(m for m in mods if m not in stdlib)
print("imports fora da stdlib:", ext)
sys.exit(0 if not ext else 1)
PY
then ok "somente biblioteca padrão"; else bad "somente biblioteca padrão"; fi

echo
echo "ai-talk: PASS=${PASS} FAIL=${FAIL}"
[[ $FAIL -eq 0 ]]
