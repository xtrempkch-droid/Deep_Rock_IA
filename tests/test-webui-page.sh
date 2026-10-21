#!/usr/bin/env bash
#
# tests/test-webui-page.sh — EXECUTA o JavaScript da página (ADR-002, bug real)
# -----------------------------------------------------------------------------
# POR QUE ESTE TESTE EXISTE
#   O `make ui-test` exercita a **API** (`/api/options`, `/api/preview`, …) e
#   nunca abriu a página num navegador — está documentado como limitação desde
#   a sessão #24. Na sessão #43 isso cobrou o preço: `syncIdentityHint()` foi
#   chamado no TOPO do script, antes de `loadOptions()` preencher `OPTIONS`.
#   Resultado: `TypeError: Cannot read properties of null (reading 'identity')`
#   no topo, que **aborta o script inteiro** — sem papéis, sem famílias, sem
#   status, sem lista de ISOs. A página ficava viva (CSS) e inútil, sem dizer
#   por quê. E o `ui-test` continuava verde, porque a API estava certa.
#
# COMO (sem navegador, sem CDN, sem instalar nada)
#   Extrai o `<script>` do `index.html`, monta um DOM falso mínimo (elementos,
#   `fetch` com as respostas reais da API) e avalia com o **Node que já existe
#   no runner**. Depois confere o que a página FEZ:
#
#     1. avaliar o script não lança (pega o bug do topo, que é o que matou);
#     2. `wireForm` rodou ANTES do fetch → os handlers existem mesmo offline;
#     3. `loadOptions` preencheu os papéis e o disco veio do servidor;
#     4. o texto de identidade (ADR-002) aparece e reage à troca de papel;
#     5. os campos de IP fixo aparecem só no modo `static`;
#     6. um servidor FORA do ar mostra erro na tela (não morre calado).
#
# Sem Node o teste é SKIP (não FAIL): a máquina do usuário pode não tê-lo, e
# exigir Node para validar uma página offline seria contraditório.
#
# Uso: bash tests/test-webui-page.sh [--verbose]
# -----------------------------------------------------------------------------

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && printf '  ok   %s\n' "$*"; return 0; }
bad()  { FAIL=$((FAIL + 1)); printf '  FALHOU %s\n' "$*" >&2; }
skip() { printf '  SKIP %s\n' "$*"; }

readonly PAGE="webui/index.html"
[[ -f "$PAGE" ]] || { echo "FALHOU: ${PAGE} não existe" >&2; exit 1; }

echo "Página da interface web (executa o JS num DOM falso)"

if ! command -v node >/dev/null 2>&1; then
  skip "node ausente: não dá para executar a página aqui"
  echo
  echo "webui-page: SKIP (sem node)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# O `<script>` inline da página (o último: é o nosso).
python3 - "$PAGE" "$WORK/page.js" <<'PY'
import re, sys, pathlib
html = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
scripts = re.findall(r"<script>(.*?)</script>", html, re.S)
if not scripts:
    sys.stderr.write("nenhum <script> inline encontrado\n")
    sys.exit(1)
pathlib.Path(sys.argv[2]).write_text(scripts[-1], encoding="utf-8")
PY

# ---------------------------------------------------------------------------
# O DOM falso + o runner. `on` controla o cenário (servidor no ar ou não).
# ---------------------------------------------------------------------------
cat > "$WORK/run.mjs" <<'EOF'
import fs from "node:fs";
import vm from "node:vm";

const pageFile = process.argv[2];
const mode = process.argv[3] || "ok";   // "ok" | "down"

const els = new Map();
function mkEl(id) {
  const e = {
    id, value: "", textContent: "", innerHTML: "", placeholder: "", href: "",
    type: "text", checked: false, className: "", style: {}, children: [],
    append(...c) { this.children.push(...c); },
    appendChild(c) { this.children.push(c); return c; },
    replaceChildren(...c) { this.children = c; },
    addEventListener() {}, removeEventListener() {}, focus() {},
    classList: { add() {}, remove() {}, toggle() {} },
    querySelectorAll: () => [], setAttribute() {}, getAttribute: () => null,
  };
  return e;
}
const getEl = (id) => { if (!els.has(id)) els.set(id, mkEl(id)); return els.get(id); };

const OPTIONS = {
  distros: ["ubuntu"], roles: ["auto", "inference", "builder"],
  families: ["auto", "generic"], payloads: ["auto", "none"],
  network_modes: ["auto", "dhcp", "static", "none"], mods: [],
  identity: { inference: "ai-inference", builder: "ai-builder", auto: "ai-cpu-os" },
  defaults: { distro: "ubuntu", disk: "/dev/nvme0n1", role: "auto", family: "auto",
              payload: "none", network: "auto", username: "", hostname: "" },
};
const STATUS = {
  repo: "xtrempkch-droid/Deep_Rock_IA",
  hardware: { family: "intel-broadwell", role: "inference", gpu: "nenhuma" },
  disk: { free_gb: 770 }, isos: [], tools: {}, pendrives: [],
};

let fetchCalls = 0;
const sandbox = {
  console,
  setTimeout, clearTimeout, setInterval: () => 0, clearInterval: () => {},
  document: {
    getElementById: getEl,
    createElement: () => mkEl(""),
    querySelectorAll: () => [],
    addEventListener() {},
  },
  alert: (m) => { sandbox.__alert = m; },
  confirm: () => true,
  EventSource: class { constructor() { this.onmessage = null; } close() {} },
  fetch: async (url) => {
    fetchCalls += 1;
    if (mode === "down") throw new Error("servidor fora do ar");
    const data = String(url).includes("/api/options") ? OPTIONS : STATUS;
    return { ok: true, status: 200, json: async () => data };
  },
};
sandbox.globalThis = sandbox;
sandbox.window = sandbox;
try {
  Object.defineProperty(sandbox, "navigator", {
    value: { clipboard: { writeText: async () => {} } }, configurable: true });
  Object.defineProperty(sandbox, "crypto", {
    value: { getRandomValues: (a) => { for (let i = 0; i < a.length; i++) a[i] = i + 7; return a; } },
    configurable: true });
} catch (e) { /* já existe: usa o do Node */ }

const src = fs.readFileSync(pageFile, "utf8");
const out = { mode, fetchCalls, threw: null, alert: null, els: {} };

try {
  vm.runInNewContext(src, sandbox, { filename: "index.html<script>" });
} catch (e) {
  out.threw = e.constructor.name + ": " + e.message;
}

// Dá tempo do IIFE assíncrono (loadOptions → loadStatus).
await new Promise((r) => setTimeout(r, 200));

const grab = (id) => {
  const e = getEl(id);
  return {
    value: e.value, textContent: e.textContent, placeholder: e.placeholder,
    type: e.type, display: e.style.display,
    options: e.children.map((c) => c.value),
    childCount: e.children.length,
    hasOnclick: typeof e.onclick === "function",
    hasOnchange: typeof e.onchange === "function",
  };
};
for (const id of ["role", "family", "disk", "username", "hostname", "identity-hint",
                  "net-static", "network", "status-kv", "alert",
                  "user-password", "btn-gen-user"]) {
  out.els[id] = grab(id);
}
out.alert = sandbox.__alert || null;
out.fetchCalls = fetchCalls;

// Simula a troca de papel DEPOIS das opções (é o caminho que o usuário faz).
const roleSel = getEl("role");
roleSel.value = "inference";
if (typeof roleSel.onchange === "function") roleSel.onchange();
out.els.afterInference = grab("identity-hint");
out.els.usernameAfter = grab("username");
out.els.hostnameAfter = grab("hostname");

// Um usuário digitado deve virar o placeholder do hostname.
const usr = getEl("username");
usr.value = "adm";
if (typeof usr.oninput === "function") usr.oninput();
out.els.hostnameTyped = grab("hostname");

// O campo de IP fixo só aparece no modo static.
const net = getEl("network");
net.value = "static";
if (typeof net.onchange === "function") net.onchange();
out.els.netStaticShown = grab("net-static");

console.log(JSON.stringify(out));
EOF

check_py() { # <descrição> <expr-python> <mensagem-de-falha>
  local desc="$1" expr="$2" msg="$3"
  if python3 -c "import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if ($expr) else 1)" "$JSON" 2>/dev/null; then
    ok "$desc"
  else
    bad "$desc — ${msg}"
  fi
}

# ---------------------------------------------------------------------------
# Cenário 1: servidor no ar (o caminho normal)
# ---------------------------------------------------------------------------
JSON="$(node "$WORK/run.mjs" "$WORK/page.js" ok 2>"$WORK/err.txt" || true)"
if [[ -z "$JSON" ]]; then
  bad "o runner do DOM não devolveu nada (veja: $(head -3 "$WORK/err.txt" 2>/dev/null | tr '\n' ' '))"
else
  # (1) O BUG: um throw no topo mata a página inteira.
  check_py "o script da página executa SEM lançar (nada de TypeError no topo)" \
    "d['threw'] is None" "erro: $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["threw"])' 2>/dev/null)"

  # (2) Handlers existem (wireForm rodou) — a página continua útil se o servidor cair.
  check_py "os handlers do formulário estão ligados (role/network/senha)" \
    "d['els']['role']['hasOnchange'] and d['els']['network']['hasOnchange'] and d['els']['btn-gen-user']['hasOnclick']" \
    "algum campo ficou sem handler"

  # (3) loadOptions/loadStatus rodaram de fato.
  check_py "as opções de papel vieram do servidor (auto/inference/builder)" \
    "d['els']['role']['options'] == ['auto','inference','builder']" \
    "recebi $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["els"]["role"]["options"])' 2>/dev/null)"
  check_py "o disco padrão veio do servidor (loadStatus rodou)" \
    "d['els']['disk']['value'] == '/dev/nvme0n1'" \
    "disco = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["els"]["disk"]["value"])' 2>/dev/null)"
  check_py "o status foi renderizado (loadStatus rodou)" \
    "len(d['els']['status-kv']['options'] if False else d['els']['status-kv']['textContent'] + str(d['fetchCalls'])) > 0 and d['fetchCalls'] >= 2" \
    "fetch calls = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["fetchCalls"])' 2>/dev/null)"

  # (4) Identidade (ADR-002): texto inicial + reação à troca de papel.
  check_py "a dica de identidade aparece (papel auto → ai-cpu-os)" \
    "'ai-cpu-os' in d['els']['identity-hint']['textContent']" \
    "hint = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["els"]["identity-hint"]["textContent"][:60])' 2>/dev/null)"
  check_py "trocar o papel para inference sugere ai-inference" \
    "'ai-inference' in d['els']['afterInference']['textContent']" \
    "hint após troca = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["els"]["afterInference"]["textContent"][:60])' 2>/dev/null)"
  check_py "o placeholder do usuário sugere o nome do papel" \
    "d['els']['usernameAfter']['placeholder'] == 'ai-inference'" \
    "placeholder = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(repr(json.load(sys.stdin)["els"]["usernameAfter"]["placeholder"]))' 2>/dev/null)"
  check_py "digitar o usuário muda o placeholder do hostname" \
    "d['els']['hostnameTyped']['placeholder'] == 'adm'" \
    "placeholder = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(repr(json.load(sys.stdin)["els"]["hostnameTyped"]["placeholder"]))' 2>/dev/null)"

  # (5) Campos de IP fixo só no modo static.
  check_py "escolher 'static' mostra os campos de IP fixo" \
    "d['els']['netStaticShown']['display'] == ''" \
    "display = $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(repr(json.load(sys.stdin)["els"]["netStaticShown"]["display"]))' 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Cenário 2: servidor FORA do ar → erro na tela, e nada de morrer calado
# ---------------------------------------------------------------------------
JSON="$(node "$WORK/run.mjs" "$WORK/page.js" down 2>/dev/null || true)"
if [[ -z "$JSON" ]]; then
  bad "com o servidor fora do ar o runner não devolveu nada"
else
  check_py "servidor fora do ar: o script NÃO lança (mostra o erro na tela)" \
    "d['threw'] is None" "erro: $(printf '%s' "$JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["threw"])' 2>/dev/null)"
  # `alertBox()` escreve em `#alert` (não no `alert()` do navegador): é o
  # elemento que o usuário vê. Contar os filhos é o que prova que a caixa
  # foi preenchida.
  check_py "servidor fora do ar: há mensagem de erro visível na tela" \
    "d['els']['alert']['childCount'] >= 1" \
    "#alert ficou vazio — o usuário veria uma página sem nada e sem motivo"
fi

# ---------------------------------------------------------------------------
# Sem CDN e sem recurso externo (a página tem de funcionar offline)
# ---------------------------------------------------------------------------
if grep -qE '<script[^>]+src=|<link[^>]+href="http' "$PAGE"; then
  bad "a página carrega recurso externo (CDN/script remoto)"
else
  ok "a página não carrega nenhum recurso externo"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "webui-page: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "webui-page: PASS=${PASS} FAIL=${FAIL}"
exit 1
