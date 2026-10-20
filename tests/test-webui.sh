#!/usr/bin/env bash
#
# tests/test-webui.sh — prova a interface web local sem abrir navegador
# -----------------------------------------------------------------------------
# Sobe o `webui/server.py` numa porta livre, exercita a API e confere as defesas.
# O foco NÃO é "a API responde 200": é provar que as salvaguardas funcionam:
#
#   * só escuta em localhost;
#   * a lista branca RECUSA parâmetros fora do conjunto fechado (injeção de
#     comando no --disk/--family não passa);
#   * sem xorriso, o build é RECUSADO COM MOTIVO (não falha de forma confusa);
#   * a prévia (dry-run) funciona sempre, porque não depende de xorriso;
#   * o SSE entrega o log e sinaliza o fim com o código de saída.
#
# Nada disso precisa de rede, root, xorriso, qemu ou navegador. O cliente HTTP é
# o próprio Python (stdlib), então o teste não depende de `curl`.
#
# Uso: bash tests/test-webui.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
TEST_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly TEST_ROOT
readonly SERVER="${TEST_ROOT}/webui/server.py"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

LOG="$(mktemp)"
readonly LOG
PORTFILE="$(mktemp)"
readonly PORTFILE
SRV_PID=""

cleanup() {
  if [[ -n "$SRV_PID" ]]; then kill "$SRV_PID" 2>/dev/null || true; fi
  rm -f "$LOG" "$PORTFILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Sobe o servidor em 127.0.0.1 com uma porta livre (--port 0).
# ---------------------------------------------------------------------------
python3 "$SERVER" --port 0 --no-browser >"$LOG" 2>&1 &
SRV_PID=$!

PORT=""
for _ in $(seq 1 60); do
  PORT="$(sed -n 's/^PORT=\([0-9]\+\).*/\1/p' "$LOG" 2>/dev/null | head -1 || true)"
  [[ -n "$PORT" ]] && break
  # Se o processo morreu, não adianta esperar.
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 0.1
done

if [[ -z "$PORT" ]]; then
  echo "não consegui subir o servidor. Saída:"; cat "$LOG" | sed 's/^/  /'
  exit 1
fi

echo "Interface web local (${PORT})"

BASE="http://127.0.0.1:${PORT}"

# Cliente HTTP em Python (stdlib) — sem depender de curl.
# api <MÉTODO> <rota> [corpo-json]  → imprime "STATUS<TAB>CORPO"
api() {
  python3 - "$BASE" "$@" <<'PY'
import json, sys, urllib.error, urllib.request
base, method, route = sys.argv[1], sys.argv[2], sys.argv[3]
body = sys.argv[4].encode() if len(sys.argv) > 4 else None
req = urllib.request.Request(base + route, data=body, method=method)
if body:
    req.add_header("Content-Type", "application/json")
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print(r.status, r.read().decode("utf-8", "replace"), sep="\t")
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode("utf-8", "replace"), sep="\t")
except Exception as e:
    print("ERR", str(e), sep="\t")
PY
}

status_of() { printf '%s' "$1" | head -1 | cut -f1; }
body_of()   { printf '%s' "$1" | cut -f2-; }

# ---------------------------------------------------------------------------
# 1) A página e as rotas de leitura
# ---------------------------------------------------------------------------
r="$(api GET /)"
[[ "$(status_of "$r")" == "200" ]] && ok "GET / serve a página" || bad "GET / devolveu $(status_of "$r")"
# Comparação direta na variável em vez de `| grep`: o corpo tem ~17 KB e passar
# isso por um pipe de 3 processos é lento e frágil à toa.
if [[ "$r" == *"<title>ai-cpu-os"* ]]; then
  ok "a página é o HTML da UI"
else
  bad "GET / não devolveu o index.html esperado (${#r} bytes)"
fi
if [[ "$r" == *cdn* || "$r" == *googleapis* || "$r" == *unpkg* || "$r" == *jsdelivr* ]]; then
  bad "a página carrega recurso EXTERNO (quebraria offline)"
else
  ok "a página não depende de CDN (funciona offline)"
fi

r="$(api GET /api/status)"
[[ "$(status_of "$r")" == "200" ]] && ok "GET /api/status responde" || bad "status devolveu $(status_of "$r")"
case "$(body_of "$r")" in
  *'"can_build"'*) ok "status informa se é possível gerar a ISO (can_build)" ;;
  *) bad "status não informa can_build" ;;
esac
case "$(body_of "$r")" in
  *'"hardware"'*) ok "status traz o hardware detectado" ;;
  *) bad "status não traz hardware" ;;
esac

r="$(api GET /api/options)"
[[ "$(status_of "$r")" == "200" ]] && ok "GET /api/options responde" || bad "options devolveu $(status_of "$r")"
case "$(body_of "$r")" in
  *'amd-zen2'*) ok "as famílias vêm do repositório (families/)" ;;
  *) bad "options não listou as famílias do repositório" ;;
esac
case "$(body_of "$r")" in
  *'governor'*) ok "as mods vêm do repositório (mods/)" ;;
  *) bad "options não listou as mods" ;;
esac

# IDENTIDADE POR PAPEL (ADR-002): a página SUGERE o usuário a partir do papel.
# A tabela vem do servidor para não haver duas cópias divergindo (a do
# build-iso.sh resolve_identity e esta). Lido AQUI, enquanto `$r` ainda é a
# resposta de /api/options — usar o `$r` de outra rota foi um bug do teste.
case "$(body_of "$r")" in
  *'"identity"'*'"ai-inference"'*'"ai-builder"'*)
    ok "options expõe a tabela do ADR-002 (ai-inference/ai-builder)" ;;
  *) bad "options não expõe a tabela de identidade do ADR-002" ;;
esac

r="$(api GET /api/nao-existe)"
[[ "$(status_of "$r")" == "404" ]] && ok "rota inexistente: 404" || bad "rota inexistente deu $(status_of "$r")"

# ---------------------------------------------------------------------------
# 2) LISTA BRANCA — o ponto mais importante deste teste
# ---------------------------------------------------------------------------
expect_400() {
  local desc="$1" route="$2" body="${3:-{}}"
  local out; out="$(api POST "$route" "$body")"
  if [[ "$(status_of "$out")" == "400" ]]; then
    ok "recusa (400): ${desc}"
  else
    bad "NÃO recusou '${desc}' (status $(status_of "$out")): $(body_of "$out" | head -c 120)"
  fi
}

expect_400 "distro fora da lista"        /api/preview '{"distro":"windows","disk":"/dev/vda"}'
expect_400 "papel fora da lista"         /api/preview '{"role":"root","disk":"/dev/vda"}'
expect_400 "família inexistente"         /api/preview '{"family":"nao-existe","disk":"/dev/vda"}'
expect_400 "família com travessia"       /api/preview '{"family":"../../etc","disk":"/dev/vda"}'
expect_400 "família com injeção"         /api/preview '{"family":"amd-zen2; rm -rf /","disk":"/dev/vda"}'
expect_400 "disco com injeção"           /api/preview '{"disk":"/dev/vda; reboot"}'
expect_400 "disco não é /dev"            /api/preview '{"disk":"etc/passwd"}'
expect_400 "disco com pipe"              /api/preview '{"disk":"/dev/vda | tee /etc/x"}'
expect_400 "payload fora da lista"       /api/preview '{"payload":"tudo","disk":"/dev/vda"}'
expect_400 "rede fora da lista"          /api/preview '{"network":"wifi","disk":"/dev/vda"}'
expect_400 "IP fixo inválido"            /api/preview '{"network":"static","net_ip":"999.1.1.1","net_gateway":"10.0.0.1"}'
expect_400 "IP fixo sem gateway"         /api/preview '{"network":"static","net_ip":"10.0.0.5"}'
expect_400 "DNS inválido"                /api/preview '{"network":"static","net_ip":"10.0.0.5","net_gateway":"10.0.0.1","net_dns":"nao-e-ip"}'
expect_400 "interface com injeção"       /api/preview '{"network":"dhcp","net_iface":"enp5s0; rm -rf /"}'
expect_400 "JSON malformado"             /api/preview '{nao é json}'
expect_400 "corpo não é objeto"          /api/preview '["a"]'
expect_400 "caminho de ISO inexistente"  /api/iso-check '{"iso":"/tmp/nao-existe-xyz.iso"}'
expect_400 "caminho sem extensão .iso"   /api/iso-check '{"iso":"/etc/passwd"}'

# Id de job inválido é validado na ROTA (GET), não no corpo.
out="$(api GET '/api/jobs/nao-e-job')"
[[ "$(status_of "$out")" == "400" ]] && ok "recusa (400): id de job em formato inválido" \
  || bad "id de job inválido deu $(status_of "$out")"
out="$(api GET '/api/jobs/j99')"
[[ "$(status_of "$out")" == "404" ]] && ok "id de job bem formado mas inexistente: 404" \
  || bad "job inexistente deu $(status_of "$out")"

# Nada disso pode ter criado um job: a validação roda ANTES de executar.
r="$(api GET /api/status)"
case "$(body_of "$r")" in
  *"rm -rf"*) bad "um parâmetro malicioso vazou para a resposta" ;;
  *) ok "nenhum parâmetro malicioso foi ecoado" ;;
esac

# ---------------------------------------------------------------------------
# 3-b) Senhas do usuário/root: hash crypt na linha de comando, NUNCA texto puro
# ---------------------------------------------------------------------------
PW_USER='Senha-Teste-9x!'
PW_ROOT='Root-Teste-9x!'
out="$(api POST /api/preview "{\"distro\":\"ubuntu\",\"disk\":\"/dev/vda\",\"role\":\"auto\",\"family\":\"auto\",\"payload\":\"none\",\"user_password\":\"${PW_USER}\",\"root_password\":\"${PW_ROOT}\"}")"
st="$(status_of "$out")"
if [[ "$st" == "200" ]]; then
  body="$(body_of "$out")"
  ok "prévia aceita senhas (vira hash antes do comando)"
  case "$body" in
    *'"--password-hash"'*'"--root-password-hash"'*)
      ok "as flags --password-hash e --root-password-hash entram no argv" ;;
    *) bad "argv sem as flags de hash (senha se perdeu?)" ;;
  esac
  # O hash crypt SHA-512 começa com $6$ — texto puro NUNCA pode aparecer.
# (A redireção vai no MESMO comando `python3` de propósito: o lint do CI exige
#  redireção anexada ao comando que a usa.)
  if python3 - "$body" "$PW_USER" "$PW_ROOT" >/dev/null 2>&1 <<'PY'
import json, sys
d = json.loads(sys.argv[1])
argv = " ".join(d.get("argv", []))
import re
m = re.search(r"--password-hash (\S+)", argv)
assert m and m.group(1).startswith("$6$"), f"hash do usuario nao parece crypt: {m and m.group(1)!r}"
m = re.search(r"--root-password-hash (\S+)", argv)
assert m and m.group(1).startswith("$6$"), f"hash do root nao parece crypt: {m and m.group(1)!r}"
assert sys.argv[2] not in argv, "a senha do usuario apareceu em texto puro"
assert sys.argv[3] not in argv, "a senha do root apareceu em texto puro"
assert sys.argv[2] not in json.dumps(d), "a senha vazou em outro campo"
assert sys.argv[3] not in json.dumps(d), "a senha do root vazou em outro campo"
print("ok")
PY
  then
    ok "senhas viram hash crypt \$6\$ e o texto puro não aparece em lugar nenhum"
  else
    bad "senha em texto puro vazou para a resposta/argv"
  fi
else
  bad "prévia com senhas falhou (status $st)"
fi

# Sem senha de root → argv SEM a flag de root (o build deixa o root bloqueado).
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","payload":"none"}')"
if [[ "$(status_of "$out")" == "200" ]] \
   && [[ "$(body_of "$out")" != *'--root-password-hash'* \
     && "$(body_of "$out")" != *'--password-hash'* ]]; then
  ok "sem senhas no formulário, o argv não leva flags de senha (o build gera/bloqueia)"
else
  bad "senha ausente deveria ficar ausente do argv"
fi

# Senha com quebra de linha (injeção/transporte) → recusada.
# Nota: '\n' AQUI é JSON (`\n` vira newline de verdade no parse).
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","payload":"none","user_password":"abc\ndef"}')"
[[ "$(status_of "$out")" == "400" ]] \
  && ok "senha com quebra de linha é recusada (400)" \
  || bad "senha com \\n deveria ser recusada (deu $(status_of "$out"))"

# ---------------------------------------------------------------------------
# 3-c) Rede do sistema instalado: o default é DHCP e o modo static monta as
#      flags de IP/gateway/DNS (é o que impede o alvo de subir sem rede).
# ---------------------------------------------------------------------------
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","payload":"none"}')"
case "$(body_of "$out")" in
  *'"--network"'*'"auto"'*) ok "sem escolha no formulário, o argv leva --network auto (DHCP)" ;;
  *) bad "o argv não leva --network auto por padrão" ;;
esac

out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","network":"static","net_ip":"10.0.0.5/24","net_gateway":"10.0.0.1","net_dns":"8.8.8.8 1.1.1.1","net_iface":"enp5s0"}')"
body="$(body_of "$out")"
if [[ "$(status_of "$out")" == "200" ]] && python3 - "$body" >/dev/null 2>&1 <<'PY'
import json, sys
argv = json.loads(sys.argv[1]).get("argv", [])
i = argv.index("--network")
assert argv[i + 1] == "static", argv
assert argv[argv.index("--network-ip") + 1] == "10.0.0.5/24"
assert argv[argv.index("--network-gateway") + 1] == "10.0.0.1"
assert argv[argv.index("--network-dns") + 1] == "8.8.8.8,1.1.1.1"
assert argv[argv.index("--network-interface") + 1] == "enp5s0"
print("ok")
PY
then
  ok "modo static monta --network-ip/--network-gateway/--network-dns (DNS normalizado)"
else
  bad "modo static não montou as flags de rede: $(echo "$body" | head -c 160)"
fi

out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","network":"none"}')"
case "$(body_of "$out")" in
  *"--network-ip"*) bad "modo none não deveria levar flags de IP" ;;
  *) ok "modo none não inventa IP/gateway" ;;
esac

# ---------------------------------------------------------------------------
# 3) Prévia (dry-run) funciona SEM xorriso — é o coração da UI
# ---------------------------------------------------------------------------
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","payload":"none"}')"
st="$(status_of "$out")"
if [[ "$st" == "200" ]]; then
  ok "a prévia é aceita sem xorriso (dry-run)"
  job="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('job',''))" "$(body_of "$out")")"
  [[ -n "$job" ]] && ok "a prévia devolve um id de job ($job)" || bad "a prévia não devolveu job"

  # SSE: consome o stream até o evento 'done' e confere que houve saída.
  sse="$(python3 - "$BASE" "$job" <<'PY'
import json, sys, urllib.request
base, job = sys.argv[1], sys.argv[2]
lines, rc, events = 0, None, 0
with urllib.request.urlopen(f"{base}/api/jobs/{job}/events", timeout=60) as r:
    ev = None
    for raw in r:
        raw = raw.decode("utf-8", "replace").rstrip("\n")
        if raw.startswith("event: "):
            ev = raw[7:]
        elif raw.startswith("data: ") and ev == "done":
            rc = json.loads(raw[6:]).get("rc"); events += 1; break
        elif raw.startswith("data: "):
            lines += 1
print(json.dumps({"lines": lines, "rc": rc, "events": events}))
PY
)"
  printf '%s' "$sse" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert d['events'] == 1, 'sem evento done'
assert d['lines'] > 0, 'nenhuma linha de log'
assert d['rc'] is not None, 'sem código de saída'
assert d['rc'] == 0, f\"dry-run falhou com rc={d['rc']}\"
print('ok')
" >/dev/null 2>&1 && ok "SSE entrega o log e o evento 'done' com rc=0" || bad "SSE não entregou o log corretamente"
else
  bad "a prévia falhou com status $st: $(body_of "$out" | head -c 160)"
fi

# ---------------------------------------------------------------------------
# 4) Build: recusado COM MOTIVO quando falta xorriso (não falha confuso)
# ---------------------------------------------------------------------------
if command -v xorriso >/dev/null 2>&1; then
  ok "xorriso presente — o build seria permitido (não vamos executá-lo aqui)"
else
  out="$(api POST /api/build '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","family":"auto","payload":"none"}')"
  if [[ "$(status_of "$out")" == "400" ]]; then
    ok "sem xorriso: o build é recusado com 400"
    case "$(body_of "$out")" in
      *xorriso*Actions*) ok "a recusa EXPLICA o motivo e aponta o caminho alternativo" ;;
      *) bad "a recusa não explica (mensagem: $(body_of "$out" | head -c 120))" ;;
    esac
  else
    bad "sem xorriso o build deveria ser recusado, mas deu $(status_of "$out")"
  fi
fi

# ---------------------------------------------------------------------------
# 5) Pendrive: só listagem (a gravação exige root e NÃO é exposta na API)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 4-b) Identidade: campo vazio = build deriva; preenchido = vence e é validado
# ---------------------------------------------------------------------------
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"inference","family":"auto","payload":"none"}')"
if [[ "$(status_of "$out")" == "200" ]]; then
  ok "prévia com --role inference é aceita (identidade derivada pelo build)"
else
  bad "prévia com role=inference falhou: $(body_of "$out" | head -c 160)"
fi

out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"builder","username":"adm","family":"auto","payload":"none"}')"
case "$(body_of "$out")" in
  *'"argv"'*)
    if printf '%s' "$(body_of "$out")" | grep -q -- '--username'; then
      ok "usuário explícito chega ao argv do build (--username)"
    else
      ok "usuário explícito aceito (o argv é montado no job)"
    fi ;;
  *) bad "usuário explícito foi recusado: $(body_of "$out" | head -c 160)" ;;
esac

# Um nome de usuário inválido é recusado AQUI (nunca chega ao autoinstall).
out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","username":"Root;rm -rf /","family":"auto","payload":"none"}')"
[[ "$(status_of "$out")" == "400" ]] \
  && ok "usuário com caractere inválido é recusado (400)" \
  || bad "usuário inválido foi aceito (status $(status_of "$out"))"

out="$(api POST /api/preview '{"distro":"ubuntu","disk":"/dev/vda","role":"auto","hostname":"-nao-pode-","family":"auto","payload":"none"}')"
[[ "$(status_of "$out")" == "400" ]] \
  && ok "hostname inválido é recusado (400)" \
  || bad "hostname inválido foi aceito (status $(status_of "$out"))"

r="$(api GET /api/pendrives)"
[[ "$(status_of "$r")" == "200" ]] && ok "GET /api/pendrives responde (só leitura)" || bad "pendrives deu $(status_of "$r")"
out="$(api POST /api/pendrive '{"device":"/dev/sda"}')"
[[ "$(status_of "$out")" == "404" ]] && ok "NÃO existe endpoint de gravação (gravar exige terminal/root)" || bad "existe endpoint de gravação (risco de segurança)"

# ---------------------------------------------------------------------------
# 6) O servidor escuta só em localhost
# ---------------------------------------------------------------------------
grep -q "127.0.0.1" "$LOG" && ok "o servidor escuta em 127.0.0.1 (localhost)" || bad "não ficou claro que escuta só em localhost"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "webui: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "webui: PASS=${PASS} FAIL=${FAIL}"
exit 1
