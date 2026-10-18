#!/usr/bin/env bash
#
# tests/test-network-mod.sh — prova a mod `network` SEM root e SEM tocar na rede
# -----------------------------------------------------------------------------
# A mod `network` existe para consertar uma máquina que subia SEM IP. Um erro
# nela tem o pior modo de falha possível: deixar o servidor sem rede. Por isso
# tudo é exercitado sobre uma ÁRVORE FALSA (`--root`), nunca no sistema real.
#
# O que é provado:
#   1. DHCP (padrão) gera o netplan com `dhcp4: true` em en*/eth*;
#   2. `--interface` gera o bloco nominal;
#   3. `--mode static` gera endereço + rota default + DNS (e exige ip/gateway);
#   4. o netplan do instalador/cloud-init é MOVIDO para .bak (o conflito que
#      deixaria o netplan recusar a config);
#   5. o cloud-init é desligado só para rede;
#   6. é IDEMPOTENTE (segunda execução não reescreve);
#   7. `revert` remove o que aplicou e RESTAURA o backup;
#   8. entradas inválidas são RECUSADAS (rc 2) e não escrevem nada;
#   9. `--dry-run` não escreve arquivo nenhum.
#
# Requer: bash, sed. Sem root, sem rede, sem netplan, sem docker.
# -----------------------------------------------------------------------------

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly APPLY="${REPO_ROOT}/mods/network/apply.sh"
readonly REVERT="${REPO_ROOT}/mods/network/revert.sh"

VERBOSE=0
[[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [[ $VERBOSE -eq 1 ]] && echo "  ok   $1"; return 0; }
bad() { FAIL=$((FAIL + 1)); echo "  FALHOU $1"; return 0; }

WORK="$(mktemp -d)"
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# Árvore falsa: um "sistema" com o netplan que o instalador deixa para trás.
mk_root() {
  local d="$1"
  rm -rf "$d"
  mkdir -p "$d/etc/netplan" "$d/etc/cloud/cloud.cfg.d"
  printf 'network:\n  version: 2\n  ethernets:\n    ens3:\n      dhcp4: true\n' \
    > "$d/etc/netplan/50-cloud-init.yaml"
  printf '%s' "$d"
}

run_apply() { bash "$APPLY" "$@" 2>&1; }
run_revert() { bash "$REVERT" "$@" 2>&1; }

echo "mod network (rede persistente) — sem root, sem rede"

# ---------------------------------------------------------------------------
# 1) DHCP (padrão): dhcp4 em en*/eth*
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/a")"
out="$(run_apply --root "$r")"
np="$r/etc/netplan/99-ai-cpu-os.yaml"
if [[ -f "$np" ]]; then ok "apply (padrão) criou 99-ai-cpu-os.yaml"; else bad "apply não criou o netplan"; fi
if grep -q 'dhcp4: true' "$np" 2>/dev/null; then ok "padrão = DHCP (dhcp4: true)"; else bad "padrão não ligou DHCP"; fi
if grep -q 'name: "en\*"' "$np" 2>/dev/null && grep -q 'name: "eth\*"' "$np" 2>/dev/null; then
  ok "casa en* e eth* (não depende do nome da placa)"
else
  bad "não casou en*/eth*"
fi
if [[ "$(stat -c %a "$np" 2>/dev/null)" == "600" ]]; then
  ok "netplan gravado com 0600 (exigência do netplan)"
else
  bad "netplan com permissão errada ($(stat -c %a "$np" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 2) O conflito que deixaria o sistema SEM rede: netplan do cloud-init
# ---------------------------------------------------------------------------
if [[ -f "$r/etc/netplan/50-cloud-init.yaml.ai-cpu-os.bak" ]] \
   && [[ ! -f "$r/etc/netplan/50-cloud-init.yaml" ]]; then
  ok "netplan do cloud-init movido para .bak (evita 'Conflicting network definitions')"
else
  bad "o netplan do cloud-init continua no caminho (conflito de definições)"
fi
ci="$r/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg"
if grep -q 'network: {config: disabled}' "$ci" 2>/dev/null; then
  ok "cloud-init com a rede desligada"
else
  bad "cloud-init não foi desligado (pode sobrescrever no próximo boot)"
fi

# ---------------------------------------------------------------------------
# 3) Idempotência: a 2ª execução não reescreve e não cria backup à toa
# ---------------------------------------------------------------------------
before="$(sha256sum "$np" | cut -d' ' -f1)"
nfiles_before="$(find "$r/etc/netplan" -type f | wc -l)"
out="$(run_apply --root "$r")"
after="$(sha256sum "$np" | cut -d' ' -f1)"
nfiles_after="$(find "$r/etc/netplan" -type f | wc -l)"
if [[ "$before" == "$after" && "$nfiles_before" == "$nfiles_after" ]]; then
  ok "idempotente: conteúdo e nº de arquivos iguais na 2ª execução"
else
  bad "não é idempotente (conteúdo ou arquivos mudaram)"
fi
case "$out" in
  *"Sem alterações"*) ok "2ª execução reporta 'Sem alterações'" ;;
  *) bad "2ª execução não reportou idempotência" ;;
esac

# ---------------------------------------------------------------------------
# 4) --interface: bloco nominal (sem glob)
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/b")"
run_apply --root "$r" --interface enp5s0 >/dev/null
np="$r/etc/netplan/99-ai-cpu-os.yaml"
if grep -q '^    enp5s0:' "$np" 2>/dev/null && ! grep -q 'all-en' "$np" 2>/dev/null; then
  ok "--interface enp5s0 gera bloco nominal (sem globs)"
else
  bad "--interface não gerou o bloco nominal"
fi

# ---------------------------------------------------------------------------
# 5) Static: endereço + rota default + DNS
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/c")"
run_apply --root "$r" --mode static --interface enp5s0 \
  --ip 192.168.1.50/24 --gateway 192.168.1.1 --dns "1.1.1.1,8.8.8.8" >/dev/null
np="$r/etc/netplan/99-ai-cpu-os.yaml"
if grep -q 'addresses: \[192.168.1.50/24\]' "$np" 2>/dev/null; then
  ok "static: addresses com o /24 informado"
else
  bad "static: endereço ausente/errado"
fi
if grep -q 'via: 192.168.1.1' "$np" 2>/dev/null; then ok "static: rota default (via gateway)"; else bad "static: sem rota default"; fi
if grep -q 'addresses: \[1.1.1.1, 8.8.8.8\]' "$np" 2>/dev/null; then
  ok "static: DNS aplicado"
else
  bad "static: DNS não aplicado"
fi

# ---------------------------------------------------------------------------
# 6) Entradas inválidas: rc 2 e NADA escrito
# ---------------------------------------------------------------------------
expect_rc2() {
  local desc="$1"; shift
  local r rc=0
  r="$(mk_root "$WORK/err")"
  bash "$APPLY" --root "$r" "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then ok "recusa (rc 2): ${desc}"; else bad "NÃO recusou '${desc}' (rc ${rc})"; fi
  if [[ ! -f "$r/etc/netplan/99-ai-cpu-os.yaml" ]]; then
    ok "  e não escreveu netplan"
  else
    bad "  escreveu um netplan inválido para '${desc}'"
  fi
}

expect_rc2 "modo desconhecido" --mode wifi
expect_rc2 "static sem --ip" --mode static --gateway 10.0.0.1
expect_rc2 "static sem --gateway" --mode static --ip 10.0.0.5/24
expect_rc2 "IP inválido" --mode static --ip 999.1.1.1 --gateway 10.0.0.1
expect_rc2 "prefixo fora de 1..32" --mode static --ip 10.0.0.5/99 --gateway 10.0.0.1
expect_rc2 "gateway inválido" --mode static --ip 10.0.0.5/24 --gateway nao-e-ip
expect_rc2 "interface com injeção" --interface 'enp5s0; rm -rf /'
expect_rc2 "argumento desconhecido" --xpto

# ---------------------------------------------------------------------------
# 7) --dry-run não toca em nada
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/d")"
run_apply --root "$r" --dry-run >/dev/null
if [[ ! -f "$r/etc/netplan/99-ai-cpu-os.yaml" ]] \
   && [[ -f "$r/etc/netplan/50-cloud-init.yaml" ]] \
   && [[ ! -f "$r/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg" ]]; then
  ok "--dry-run: nada escrito, nada movido"
else
  bad "--dry-run mexeu no sistema"
fi

# ---------------------------------------------------------------------------
# 8) --mode none não grava configuração
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/e")"
run_apply --root "$r" --mode none >/dev/null
if [[ ! -f "$r/etc/netplan/99-ai-cpu-os.yaml" ]]; then
  ok "--mode none não grava netplan (e avisa que a placa pode subir DOWN)"
else
  bad "--mode none gravou configuração"
fi

# ---------------------------------------------------------------------------
# 9) revert: remove o que aplicou e RESTAURA o backup
# ---------------------------------------------------------------------------
r="$(mk_root "$WORK/f")"
run_apply --root "$r" >/dev/null
out="$(run_revert --root "$r")"
if [[ ! -f "$r/etc/netplan/99-ai-cpu-os.yaml" ]]; then ok "revert removeu o netplan do ai-cpu-os"; else bad "revert não removeu"; fi
if [[ ! -f "$r/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg" ]]; then
  ok "revert removeu o arquivo do cloud-init"
else
  bad "revert deixou o arquivo do cloud-init"
fi
if [[ -f "$r/etc/netplan/50-cloud-init.yaml" ]] \
   && [[ ! -f "$r/etc/netplan/50-cloud-init.yaml.ai-cpu-os.bak" ]]; then
  ok "revert RESTAUROU o netplan original (não deixa sem rede)"
else
  bad "revert não restaurou o netplan original"
fi
out="$(run_revert --root "$r")"
case "$out" in
  *"Nada a fazer"*|*"idempotente"*) ok "revert é idempotente" ;;
  *) bad "revert não é idempotente" ;;
esac

# ---------------------------------------------------------------------------
# 10) Catálogo: a mod aparece em `apply.sh list` com o conjunto próprio
# ---------------------------------------------------------------------------
if grep -q '^MOD_ID="network"' "${REPO_ROOT}/mods/network/mod.conf"; then
  ok "mod.conf declara MOD_ID=network"
else
  bad "mod.conf sem MOD_ID"
fi
case "$(bash "${REPO_ROOT}/mods/apply.sh" list 2>/dev/null)" in
  *network*) ok "mods/apply.sh list mostra a mod network" ;;
  *) bad "mods/apply.sh list NÃO mostra a mod network" ;;
esac
if grep -q '^MOD_SETS="network"' "${REPO_ROOT}/mods/network/mod.conf"; then
  ok "conjunto próprio ('network'): não entra em 'system'/'portable'"
else
  bad "a mod não tem conjunto próprio (poderia mexer na rede em apply --set system)"
fi

# ---------------------------------------------------------------------------
# 10-b) O aviso que evita "rodei e continuou sem rede"
# ---------------------------------------------------------------------------
# Um netplan VÁLIDO que não casa com placa nenhuma é um sucesso do script e um
# fracasso do objetivo. Simulamos uma máquina cuja placa é `wlp3s0` (Wi-Fi) via
# NET_SYSFS e exigimos o aviso com o nome real da placa.
r="$(mk_root "$WORK/g")"
mkdir -p "$WORK/fakenet/wlp3s0/device"
out="$(NET_SYSFS="$WORK/fakenet" run_apply --root "$r")"
case "$out" in
  *"não vai pegar NADA"*) ok "avisa quando nenhuma placa casa en*/eth*" ;;
  *) bad "não avisou que o netplan não casaria nenhuma placa" ;;
esac
case "$out" in
  *"--interface wlp3s0"*) ok "o aviso sugere a placa REAL (--interface wlp3s0)" ;;
  *) bad "o aviso não sugere a placa encontrada" ;;
esac

# Com --interface explícito, NÃO pode avisar (o usuário já resolveu).
r="$(mk_root "$WORK/h")"
out="$(NET_SYSFS="$WORK/fakenet" run_apply --root "$r" --interface wlp3s0)"
case "$out" in
  *"não vai pegar NADA"*) bad "avisou mesmo com --interface explícito" ;;
  *) ok "com --interface explícito não há aviso (nada a corrigir)" ;;
esac

# Placa que casa `en*` não gera aviso.
r="$(mk_root "$WORK/i")"
mkdir -p "$WORK/fakenet2/enp5s0/device"
out="$(NET_SYSFS="$WORK/fakenet2" run_apply --root "$r")"
case "$out" in
  *"não vai pegar NADA"*) bad "avisou 'não pega nada' com enp5s0 (falso positivo)" ;;
  *) ok "enp5s0 casa en*: sem aviso" ;;
esac

# ---------------------------------------------------------------------------
# 11) OPCIONAL: o netplan REAL aceita o YAML que geramos?
# ---------------------------------------------------------------------------
# Os testes acima provam o que a mod ESCREVE; este prova que o **netplan de
# verdade** aceita. Precisa de docker e de rede (apt install netplan.io), então
# é opt-in — CI determinístico não pode depender de baixar pacote:
#
#     NETPLAN_REAL=1 bash tests/test-network-mod.sh
#
# E é só leitura sobre a rede: `--root` escreve numa árvore falsa e o
# `netplan generate` apenas converte em unidades, sem aplicar nada.
if [[ "${NETPLAN_REAL:-0}" == "1" ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "  SKIP netplan real (docker ausente)"
  elif timeout 300 docker run --rm -v "${REPO_ROOT}/mods/network:/mod:ro" ubuntu:24.04 bash -c '
        set -e
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq netplan.io >/dev/null 2>&1
        mkdir -p /alvo/etc/netplan /alvo2/etc/netplan
        bash /mod/apply.sh --root /alvo >/dev/null
        netplan generate --root-dir /alvo >/dev/null 2>&1
        grep -q "DHCP=ipv4" /alvo/run/systemd/network/10-netplan-all-en.network
        bash /mod/apply.sh --root /alvo2 --mode static              --interface enp5s0 --ip 192.168.1.50/24 --gateway 192.168.1.1 >/dev/null
        netplan generate --root-dir /alvo2 >/dev/null 2>&1
        grep -q "192.168.1.50/24" /alvo2/run/systemd/network/10-netplan-enp5s0.network
      ' >/dev/null 2>&1; then
    ok "netplan REAL aceita o YAML (DHCP e static geram unidades válidas)"
  else
    bad "o netplan real RECUSOU o YAML gerado pela mod"
  fi
else
  echo "  SKIP netplan real (rode com NETPLAN_REAL=1 para exercitar em container)"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "mod-network: PASS=${PASS} FAIL=0"
  exit 0
fi
echo "mod-network: PASS=${PASS} FAIL=${FAIL}"
exit 1
