#!/usr/bin/env bash
#
# tests/test-ai-talk-install.sh — prova o `talk/install.sh` (F2 do ADR-003)
# -----------------------------------------------------------------------------
# POR QUE ESTE TESTE EXISTE
#   A F1 provou o TRANSPORTE (`make talk-test`). Mas o chat só existe numa
#   máquina instalada se quatro coisas chatas estiverem certas ao mesmo tempo:
#   o usuário de sistema, o config (com as permissões certas), as chaves e a
#   unit do systemd. Errar qualquer uma dá o mesmo sintoma: o serviço não sobe
#   e ninguém entende por quê.
#
#   Pior: dois modos de falha SILENCIOSOS são fáceis de introduzir e caros de
#   descobrir em produção —
#     * o serviço subir SEM chave (canal sem HMAC não autentica ninguém);
#     * a chave por nó não entrar na config e o nó cair na chave global sem
#       ninguém notar (aí qualquer nó assina como outro).
#
#   Este teste planta os dois e exige a recusa/aviso correto.
#
# COMO: tudo com `--root`, que escreve sob um diretório temporário e **não**
# toca no sistema (sem `useradd`, sem `systemctl`, sem `/etc`). Sem root, sem
# rede, sem serviço.
#
# Uso: bash tests/test-ai-talk-install.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && printf '  ok   %s\n' "$*"; return 0; }
bad() { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }

INSTALL="talk/install.sh"
UNIT="talk/ai-talk.service"
[[ -f "$INSTALL" ]] || { echo "FALHOU: ${INSTALL} não existe" >&2; exit 1; }
[[ -f "$UNIT" ]]    || { echo "FALHOU: ${UNIT} não existe" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
readonly WORK

# Saída inteira em variável: nada de `grep -q` em pipeline com pipefail (SIGPIPE
# já custou três sessões neste projeto).
run_install() {
  local root="$1"; shift
  bash "$INSTALL" --root "$root" --yes "$@" 2>&1 || true
}
rc_install() {
  local root="$1"; shift
  local rc=0
  bash "$INSTALL" --root "$root" --yes "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

new_key() {  # <arquivo>
  head -c 32 /dev/urandom | xxd -p -c64 > "$1"
  chmod 640 "$1"
}

echo "Instalador do chat da frota (ADR-003, F2)"

# ---------------------------------------------------------------------------
# 1) Instalação completa: arquivos, permissões e config
# ---------------------------------------------------------------------------
R="${WORK}/ok"
mkdir -p "${WORK}/keys"
new_key "${WORK}/fleet.key"
new_key "${WORK}/keys/ai-builder.key"
out="$(run_install "$R" --node ai-inference --role inference \
        --peer ai-builder=192.168.0.20 \
        --key-file "${WORK}/fleet.key" --keydir "${WORK}/keys")"

for f in etc/ai-talk/config.json \
         etc/ai-talk/fleet.key \
         etc/ai-talk/keys/ai-builder.key \
         usr/local/bin/ai-talk \
         usr/local/lib/ai-talk/ai_talk.py \
         etc/systemd/system/ai-talk.service; do
  if [[ -f "$R/$f" ]]; then ok "instalou $f"; else bad "NÃO instalou $f"; fi
done

# Permissões: config/chave 0640 (o daemon recusa chave legível por "outros");
# o wrapper é executável.
perm() { stat -c '%a' "$1" 2>/dev/null || echo '???'; }
[[ "$(perm "$R/etc/ai-talk/config.json")" == "640" ]] \
  && ok "config com modo 0640" || bad "config com modo $(perm "$R/etc/ai-talk/config.json") (esperado 640)"
[[ "$(perm "$R/etc/ai-talk/fleet.key")" == "640" ]] \
  && ok "chave global com modo 0640" || bad "chave global com modo $(perm "$R/etc/ai-talk/fleet.key")"
[[ "$(perm "$R/usr/local/bin/ai-talk")" == "755" ]] \
  && ok "wrapper ai-talk é executável (0755)" || bad "wrapper sem bit de execução"

# ---------------------------------------------------------------------------
# 2) O config é o CONTRATO do daemon (e os caminhos são do ALVO, não do --root)
# ---------------------------------------------------------------------------
cfg="$R/etc/ai-talk/config.json"
python3 - "$cfg" <<'PY' && ok "config: node/papel/porta/peers corretos" || bad "config com node/papel/porta/peers errados"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["node"] == "ai-inference", d["node"]
assert d["role"] == "inference", d["role"]
assert d["listen"]["port"] == 7331, d["listen"]
assert d["listen"]["address"] == "0.0.0.0", d["listen"]
assert list(d["peers"]) == ["ai-builder"], d["peers"]
assert d["peers"]["ai-builder"]["addr"] == "192.168.0.20", d["peers"]
PY

# O BUG que este teste existe para pegar: os caminhos gravados na config têm de
# ser /etc/ai-talk/… (do alvo). Gravar o caminho prefixado pelo --root produz
# uma config que só funciona na máquina de teste — e no alvo o daemon morre.
python3 - "$cfg" <<'PY' && ok "config aponta para caminhos do ALVO (/etc/ai-talk/…)" || bad "config com caminho prefixado pelo --root (só funcionaria na máquina de teste)"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["key_file"] == "/etc/ai-talk/fleet.key", d["key_file"]
assert d["peers"]["ai-builder"]["key_file"] == "/etc/ai-talk/keys/ai-builder.key", d["peers"]["ai-builder"]
assert d["log"]["path"] == "/var/lib/ai-talk/messages.jsonl", d["log"]["path"]
PY

# A chave POR NÓ tem de estar no peer. Se ela sumir, o nó cai na chave global e
# qualquer membro da frota pode assinar como outro (ADR-005).
python3 - "$cfg" <<'PY' && ok "chave POR NÓ entrou no peer (anti-spoof do ADR-005)" || bad "chave por nó não entrou no peer (cairia na chave global)"
import json, sys
d = json.load(open(sys.argv[1]))
assert "key_file" in d["peers"]["ai-builder"], d["peers"]["ai-builder"]
PY

# Os valores do §6.7/§6.8 (do contrato) têm de estar no config gerado: um
# default divergente aqui mudaria a latência sem ninguém perceber.
python3 - "$cfg" <<'PY' && ok "config carrega os limites/tempos do contrato (50 ms, fila 256, fsync always)" || bad "config NÃO carrega os limites/tempos do contrato"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["timing"]["min_interval_ms"] == 50, d["timing"]
assert d["timing"]["queue_max"] == 256, d["timing"]
assert d["limits"]["dedupe_window"] == 8192, d["limits"]
assert d["limits"]["max_out_per_sec"] == 120, d["limits"]
assert d["log"]["fsync"] == "always", d["log"]
assert d["log"]["control"] is False, d["log"]
PY

# ---------------------------------------------------------------------------
# 3) A unit do systemd: endurecimento do §9 + o comando certo
# ---------------------------------------------------------------------------
grep -q 'ExecStart=/usr/local/bin/ai-talk serve --config /etc/ai-talk/config.json' "$UNIT" \
  && ok "unit: ExecStart chama o serve com o config" || bad "unit: ExecStart errado"
for knob in NoNewPrivileges ProtectSystem ProtectHome PrivateTmp RestrictAddressFamilies; do
  grep -q "^${knob}=" "$UNIT" && ok "unit: ${knob} presente (endurecimento §9)" || bad "unit: ${knob} ausente"
done
grep -q '^User=ai-talk' "$UNIT" && grep -q '^Group=ai-talk' "$UNIT" \
  && ok "unit: roda como o usuário de sistema 'ai-talk'" || bad "unit: não roda como 'ai-talk'"
grep -q 'chave' /dev/null 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4) IDEMPOTÊNCIA: rodar duas vezes não muda o config
# ---------------------------------------------------------------------------
before="$(md5sum "$cfg" | cut -d' ' -f1)"
run_install "$R" --node ai-inference --role inference \
  --peer ai-builder=192.168.0.20 \
  --key-file "${WORK}/fleet.key" --keydir "${WORK}/keys" >/dev/null
after="$(md5sum "$cfg" | cut -d' ' -f1)"
[[ "$before" == "$after" ]] && ok "idempotente: rodar duas vezes mantém o config" \
  || bad "NÃO é idempotente: o config mudou na segunda execução"

# ---------------------------------------------------------------------------
# 5) SEM CHAVE → serviço DESABILITADO e aviso (nunca canal sem HMAC)
# ---------------------------------------------------------------------------
out="$(run_install "${WORK}/sem-chave" --node ai-inference --peer ai-builder=10.0.0.2)"
case "$out" in
  *"NÃO habilitado"*|*"NÃO será habilitado"*|*"DESABILITADO"*)
    ok "sem chave: avisa que o serviço fica desabilitado" ;;
  *) bad "sem chave: não avisou que o serviço fica desabilitado" ;;
esac
case "$out" in
  *"sem HMAC"*|*"não autentica"*)
    ok "sem chave: explica POR QUE (canal sem HMAC não autentica)" ;;
  *) bad "sem chave: não explica o motivo" ;;
esac
if [[ -f "${WORK}/sem-chave/etc/ai-talk/config.json" ]]; then
  ok "sem chave: o config é escrito mesmo assim (ficar pronto é útil)"
else
  bad "sem chave: nada foi escrito (não dá para completar depois sem refazer)"
fi

# ---------------------------------------------------------------------------
# 5-b) MODO "UMA CHAVE POR NÓ" (--keydir): a chave do PRÓPRIO nó tem de existir
# ---------------------------------------------------------------------------
# Este bloco existe por um bug real: com apenas `--keydir` (o modo recomendado
# pelo ADR-005), a config apontava para /etc/ai-talk/fleet.key — que não existe
# nesse modo — e o daemon MORRIA no start. O serviço era habilitado assim mesmo.
RKD="${WORK}/keydir"
mkdir -p "$RKD"
new_key "${RKD}/ai-inference.key"      # a chave do PRÓPRIO nó (assina)
new_key "${RKD}/ai-builder.key"        # a chave do peer (verifica)
out="$(run_install "${WORK}/kd" --node ai-inference --role inference \
        --keydir "$RKD" --peer ai-builder=192.168.0.20)"

cfg_kd="${WORK}/kd/etc/ai-talk/config.json"
if [[ -f "$cfg_kd" ]]; then
  ok "--keydir: config gerado (sem --key-file)"
  # A chave própria TEM de virar o `key_file` — é o que permite assinar.
  if python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get('key_file') == '/etc/ai-talk/keys/ai-inference.key' else 1)" "$cfg_kd"; then
    ok "--keydir: a chave do nó (ai-inference.key) virou o key_file da config"
  else
    bad "--keydir: key_file não aponta para a chave do nó (o daemon não assinaria)"
  fi
  # E o arquivo tem de existir NO ALVO (sob o --root, no caminho simulado).
  if [[ -f "${WORK}/kd/etc/ai-talk/keys/ai-inference.key" ]]; then
    ok "--keydir: a chave do nó foi copiada para o alvo"
  else
    bad "--keydir: a chave do nó NÃO foi copiada para o alvo"
  fi
  # O daemon tem de conseguir ler a chave com que assina. Aqui o caminho é do
  # alvo (/etc/...), então apontamos o leitor para a cópia local.
  if python3 - "$cfg_kd" "${WORK}/kd" <<'PY'
import importlib.util, json, sys
cfg_path, root = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ai_talk", "talk/ai_talk.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cfg = m.load_config(cfg_path)
# Remapeia /etc/ai-talk → <root>/etc/ai-talk (é o mesmo arquivo no alvo).
def remap(p): return p.replace("/etc/ai-talk", root + "/etc/ai-talk")
m.read_key(remap(cfg["key_file"]))
for name in cfg["peers"]:
    path = m.peer_key_file(cfg, name)
    if path:
        m.read_key(remap(path))
PY
  then
    ok "--keydir: o daemon consegue ler TODAS as chaves (própria + peers)"
  else
    bad "--keydir: o daemon NÃO conseguiria ler as chaves (não iniciaria no alvo)"
  fi
else
  bad "--keydir: nenhum config foi gerado"
fi

# Só chaves de PEERS, sem a do próprio nó → o serviço NÃO pode ser habilitado.
RO="${WORK}/so-peers"
mkdir -p "$RO"
new_key "${RO}/ai-builder.key"
out="$(run_install "${WORK}/sp" --node ai-inference --keydir "$RO" --peer ai-builder=10.0.0.2)"
case "$out" in
  *"PRÓPRIO nó"*|*"sem ela o serviço não consegue assinar"*)
    ok "só chave de peer (sem ai-inference.key): avisa que não dá para assinar" ;;
  *) bad "só chave de peer: não avisou que falta a chave do próprio nó" ;;
esac
case "$out" in
  *"NÃO habilitado"*|*"NÃO será habilitado"*|*"DESABILITADO"*)
    ok "só chave de peer: o serviço fica desabilitado (não subiria mesmo)" ;;
  *) bad "só chave de peer: o serviço seria habilitado e morreria no start" ;;
esac

# Chave de um nó que não é peer E não é o próprio → aviso de órfã, e só agora
# (o aviso tem de vir DEPOIS de ler a frota, senão todo peer do arquivo seria
# acusado de órfão — bug real, sessão #46).
RO2="${WORK}/orfas"
mkdir -p "$RO2"
new_key "${RO2}/ai-inference.key"
new_key "${RO2}/ai-builder.key"
new_key "${RO2}/ai-fantasma.key"
printf 'ai-builder=10.0.0.2\n' > "${WORK}/frota-1.txt"
out="$(run_install "${WORK}/of" --node ai-inference --keydir "$RO2" --peers-file "${WORK}/frota-1.txt")"
case "$out" in
  *"ai-fantasma"*"sem peer"*)
    ok "chave órfã (nó que não é peer) é avisada" ;;
  *) bad "chave órfã não foi avisada" ;;
esac
case "$out" in
  *"ai-builder.key sem peer"*)
    bad "peer vindo do ARQUIVO foi acusado de órfão (a checagem roda antes da frota)" ;;
  *) ok "peer vindo do arquivo de frota NÃO é acusado de órfão" ;;
esac

# ---------------------------------------------------------------------------
# 6) ERROS DE USO → exit 2 (entrada do usuário; nada de ISO pela metade)
# ---------------------------------------------------------------------------
expect_rc() { # <descrição> <esperado> <args...>
  local desc="$1" want="$2"; shift 2
  local got
  got="$(rc_install "${WORK}/erro-$RANDOM" "$@")"
  if [[ "$got" == "$want" ]]; then ok "${desc} → rc ${want}"
  else bad "${desc}: rc=${got} (esperado ${want})"; fi
}

new_key "${WORK}/k644"; chmod 644 "${WORK}/k644"
expect_rc "chave legível por 'outros'" 2 --node n1 --key-file "${WORK}/k644" --peer p=10.0.0.2

expect_rc "porta inválida" 2 --node n1 --port 99999 --peer p=10.0.0.2

expect_rc "peer com o mesmo nome do nó" 2 --node ai-inference --peer ai-inference=10.0.0.9

expect_rc "peer sem '='" 2 --node n1 --peer so-um-nome

printf 'nao-tem-igual\n' > "${WORK}/frota-ruim"
expect_rc "arquivo de frota com linha inválida" 2 --node n1 --peers-file "${WORK}/frota-ruim"

expect_rc "chave com tamanho errado" 2 --node n1 --key-file "${WORK}/frota-ruim" --peer p=10.0.0.2

# Teto de 15 nós (ADR-005): acima disso é relay/hub, não "mais um pouco".
args=()
for i in $(seq 1 16); do args+=(--peer "p${i}=10.0.0.${i}"); done
new_key "${WORK}/k-ok"
expect_rc "16 peers excedem o teto de 15 (ADR-005)" 2 --node n1 --key-file "${WORK}/k-ok" "${args[@]}"

# ---------------------------------------------------------------------------
# 7) QUINZE peers é o TETO SUPORTADO — tem de funcionar
# ---------------------------------------------------------------------------
R15="${WORK}/quinze"
args=()
for i in $(seq 1 15); do args+=(--peer "p${i}=10.0.0.${i}"); done
rc="$(rc_install "$R15" --node n1 --key-file "${WORK}/k-ok" "${args[@]}")"
if [[ "$rc" == "0" ]]; then
  ok "15 peers é aceito (o teto do ADR-005 é 15, não 14)"
else
  bad "15 peers foi recusado (rc=${rc}) — o teto é 15"
fi
if [[ -f "$R15/etc/ai-talk/config.json" ]]; then
  n="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["peers"]))' "$R15/etc/ai-talk/config.json")"
  [[ "$n" == "15" ]] && ok "os 15 peers chegaram ao config" || bad "só ${n} peers no config (esperado 15)"
fi

# ---------------------------------------------------------------------------
# 8) --peers-file: a fonte da frota (uma linha por nó) e o --peer como exceção
# ---------------------------------------------------------------------------
cat > "${WORK}/frota.txt" <<'FROTA'
# frota do laboratório
ai-builder=192.168.0.20
ai-worker-07=192.168.0.27   # comentário na mesma linha
FROTA
RF="${WORK}/frota"
run_install "$RF" --node ai-inference --peers-file "${WORK}/frota.txt" \
  --key-file "${WORK}/fleet.key" --peer ai-worker-07=192.168.0.99 >/dev/null
python3 - "$RF/etc/ai-talk/config.json" <<'PY' && ok "--peers-file lido + --peer sobrepõe o arquivo" || bad "--peers-file/--peer não produziram os peers esperados"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["peers"]["ai-builder"]["addr"] == "192.168.0.20", d["peers"]
# A exceção explícita vence a fonte — é o que permite corrigir um IP pontual.
assert d["peers"]["ai-worker-07"]["addr"] == "192.168.0.99", d["peers"]
PY
if [[ -f "$RF/etc/ai-talk/peers.txt" ]]; then
  ok "--peers-file é copiado para /etc/ai-talk/peers.txt (fica auditável no alvo)"
else
  bad "--peers-file não foi copiado para o alvo"
fi

# ---------------------------------------------------------------------------
# 9) --dry-run não escreve NADA (é o que permite simular antes de gerar ISO)
# ---------------------------------------------------------------------------
RD="${WORK}/dry"
bash "$INSTALL" --root "$RD" --node n1 --peer p=10.0.0.2 --dry-run >/dev/null 2>&1
if [[ -z "$(find "$RD" -mindepth 1 2>/dev/null | head -1)" ]]; then
  ok "--dry-run: não criou nenhum arquivo"
else
  bad "--dry-run criou arquivos (não é simulação)"
fi

# ---------------------------------------------------------------------------
# 10) --status: relata sem alterar (e diz o que falta)
# ---------------------------------------------------------------------------
out="$(bash "$INSTALL" --root "$R" --status 2>&1 || true)"
case "$out" in
  *"config:"*"unit:"*) ok "--status relata config e unit do --root" ;;
  *) bad "--status não relatou config/unit" ;;
esac
out="$(bash "$INSTALL" --root "${WORK}/nao-existe" --status 2>&1 || true)"
case "$out" in
  *"AUSENTE"*) ok "--status de árvore vazia avisa o que falta" ;;
  *) bad "--status de árvore vazia não avisou nada" ;;
esac

# ---------------------------------------------------------------------------
# 11) O install.sh NÃO pode baixar nada (ISO air-gapped, Regra 13-b)
# ---------------------------------------------------------------------------
if grep -qE '\b(curl|wget|git clone|pip install|apt-get install)\b' "$INSTALL"; then
  bad "install.sh menciona download/instalação (a ISO é air-gapped)"
else
  ok "install.sh não baixa nada (air-gapped)"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "ai-talk-install: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "ai-talk-install: PASS=${PASS} FAIL=${FAIL}"
exit 1
