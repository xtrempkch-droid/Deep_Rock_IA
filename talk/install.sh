#!/usr/bin/env bash
#
# talk/install.sh — instala o chat da frota (`ai-talk`) no sistema
# -----------------------------------------------------------------------------
# POR QUE ESTE SCRIPT EXISTE
#   O `talk/ai_talk.py` (F1) é só o transporte: daemon + CLI. Para o chat
#   existir numa máquina instalada faltam quatro coisas chatas de fazer à mão e
#   fáceis de errar: o usuário de sistema, o config (com as permissões certas),
#   as chaves da frota e a unit do systemd. Este script faz as quatro, de forma
#   IDEMPOTENTE, com `--dry-run`, e degrada em vez de abortar (Regra 13-a).
#
# DECISÕES QUE ESTE SCRIPT MATERIALIZA (docs/CHAT.md)
#   * Sem chave NÃO se abre canal: o serviço é instalado **desabilitado** e o
#     script avisa. Um chat sem HMAC não é aceitável, e não existe chave
#     default (uma chave pública no repositório não autentica ninguém).
#   * A chave global serve de fallback; a chave por nó (uma por peer, em
#     `keys/<nome>.key`) é o modo recomendado para frota (ADR-005).
#   * Teto de 15 peers — acima disso o `load_config` do próprio ai-talk já
#     recusa; aqui recusamos antes de escrever qualquer arquivo.
#   * Nada é baixado: o código veio na ISO (ou do repositório clonado).
#   * O serviço **não** pode impedir a inferência de subir: quem chama
#     (`build.sh` etapa 2.5) trata falha como aviso.
#
# Uso:
#   sudo bash talk/install.sh --node ai-inference --peer ai-builder=192.168.0.20 \
#        --key-file /etc/ai-talk/fleet.key
#   sudo bash talk/install.sh --node ai-builder --peers-file frota.txt --keydir keys/
#   sudo bash talk/install.sh --status            # só relata (não altera nada)
#   sudo bash talk/install.sh --root /mnt/alvo    # prepara OUTRO sistema (teste)
#   sudo bash talk/install.sh --dry-run
#
# Flags:
#   --node NAME          nome do nó (padrão: hostname; ADR-002 já dá ai-*)
#   --role NAME          papel gravado no config (inference|builder|auto)
#   --port N             porta TCP (padrão 7331)
#   --bind ADDR          endereço de escuta (padrão 0.0.0.0)
#   --peer NAME=IP       peer individual (repetível)
#   --peers-file PATH    arquivo com uma linha "nome=ip" por nó (# e vazio ok)
#   --key-file PATH      chave GLOBAL de fallback (fica em /etc/ai-talk/)
#   --keydir DIR         diretório com uma chave por nó (<nome>.key)
#   --no-service         escreve config/chaves e NÃO habilita o serviço
#   --no-start           habilita mas não inicia agora
#   --root DIR           instala sob DIR (sem useradd/systemctl) — para testes
#   --status             relata o estado e sai (0 instalado e ativo)
#   --dry-run            mostra o que faria; não escreve nada
#   --yes                não pergunta nada
#   -h | --help          esta ajuda
#
# Exit codes: 0 ok (ou nada a fazer) · 1 falha real · 2 erro de uso.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SRC="${SCRIPT_DIR}/ai_talk.py"

NODE=""
ROLE="auto"
PORT=7331
BIND_ADDR="0.0.0.0"
KEY_FILE=""
KEYDIR=""
PEERS_FILE=""
ENABLE_SERVICE=1
START_SERVICE=1
TARGET_ROOT="/"
DRY_RUN=0
ASSUME_YES=0
STATUS_ONLY=0

readonly SVC_USER="ai-talk"
readonly SVC_GROUP="ai-talk"
readonly MAX_PEERS=15

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR" "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK" "$(_ts)" "$*" "$C_RESET"; }

usage() { sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# Pares coletados em --peer (arrays paralelos: bash 4 tem mapas, mas listas
# preservam a ordem em que o usuário digitou — e a mensagem de erro fica melhor).
PEER_NAMES=()
PEER_ADDRS=()

add_peer() {
  local spec="$1" name addr
  [[ "$spec" == *=* ]] || { log_error "--peer espera NOME=IP (recebi '${spec}')"; exit 2; }
  name="${spec%%=*}"
  addr="${spec#*=}"
  [[ -n "$name" && -n "$addr" ]] || { log_error "--peer com nome ou IP vazio: '${spec}'"; exit 2; }
  if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    log_error "nome de peer inválido: '${name}' (minúsculas, dígitos e '-')"
    exit 2
  fi
  PEER_NAMES+=("$name")
  PEER_ADDRS+=("$addr")
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node)        [[ $# -ge 2 ]] || { log_error "--node exige valor"; exit 2; }; NODE="$2"; shift 2 ;;
    --role)        [[ $# -ge 2 ]] || { log_error "--role exige valor"; exit 2; }; ROLE="$2"; shift 2 ;;
    --port)        [[ $# -ge 2 ]] || { log_error "--port exige valor"; exit 2; }; PORT="$2"; shift 2 ;;
    --bind)        [[ $# -ge 2 ]] || { log_error "--bind exige valor"; exit 2; }; BIND_ADDR="$2"; shift 2 ;;
    --peer)        [[ $# -ge 2 ]] || { log_error "--peer exige NOME=IP"; exit 2; }; add_peer "$2"; shift 2 ;;
    --peers-file)  [[ $# -ge 2 ]] || { log_error "--peers-file exige caminho"; exit 2; }; PEERS_FILE="$2"; shift 2 ;;
    --key-file)    [[ $# -ge 2 ]] || { log_error "--key-file exige caminho"; exit 2; }; KEY_FILE="$2"; shift 2 ;;
    --keydir)      [[ $# -ge 2 ]] || { log_error "--keydir exige caminho"; exit 2; }; KEYDIR="$2"; shift 2 ;;
    --no-service)  ENABLE_SERVICE=0; shift ;;
    --no-start)    START_SERVICE=0; shift ;;
    --root)        [[ $# -ge 2 ]] || { log_error "--root exige caminho"; exit 2; }; TARGET_ROOT="$2"; shift 2 ;;
    --status)      STATUS_ONLY=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --yes)         ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
  esac
done

# Caminhos (prefixados por --root). `--root` existe para TESTE e para preparar
# um disco montado: nada é executado no sistema em execução.
p() { printf '%s%s' "${TARGET_ROOT%/}" "$1"; }
# Declarar e atribuir em linhas separadas: `readonly X="$(cmd)"` mascara o
# status de `cmd` (SC2155), e aqui o caminho é a única coisa que pode falhar.
ETC_DIR="$(p /etc/ai-talk)"; readonly ETC_DIR
KEYS_DIR="${ETC_DIR}/keys"; readonly KEYS_DIR
LIB_DIR="$(p /var/lib/ai-talk)"; readonly LIB_DIR
BIN_PATH="$(p /usr/local/bin/ai-talk)"; readonly BIN_PATH
LIB_PY="$(p /usr/local/lib/ai-talk/ai_talk.py)"; readonly LIB_PY
UNIT_PATH="$(p /etc/systemd/system/ai-talk.service)"; readonly UNIT_PATH
CONFIG_PATH="${ETC_DIR}/config.json"; readonly CONFIG_PATH
PEERS_COPY="${ETC_DIR}/peers.txt"; readonly PEERS_COPY
KEY_COPY="${ETC_DIR}/fleet.key"; readonly KEY_COPY
# Os caminhos que vão ESCRITOS na config são do ALVO: com `--root` o arquivo
# está sob $T mas, ao bootar, ele precisa apontar para /etc/ai-talk/… — gravar
# o caminho prefixado produziria uma config que só funciona na máquina de teste.
KEY_COPY_CFG="/etc/ai-talk/fleet.key"; readonly KEY_COPY_CFG
KEYS_DIR_CFG="/etc/ai-talk/keys"; readonly KEYS_DIR_CFG

# ---------------------------------------------------------------------------
# --status: relatar e sair (nunca altera nada, nunca exige root)
# ---------------------------------------------------------------------------
if [[ $STATUS_ONLY -eq 1 ]]; then
  rc=0
  if [[ -x "$BIN_PATH" ]]; then
    log_info "binário: ${BIN_PATH}"
  elif command -v ai-talk >/dev/null 2>&1; then
    log_info "binário: $(command -v ai-talk) (fora de ${TARGET_ROOT})"
  else
    log_warn "binário ai-talk AUSENTE"
    rc=1
  fi
  if [[ -f "$CONFIG_PATH" ]]; then
    log_info "config: ${CONFIG_PATH} ($(stat -c '%a %U:%G' "$CONFIG_PATH" 2>/dev/null || echo '?'))"
    if [[ $DRY_RUN -eq 0 ]] && [[ -f "$BIN_PATH" ]] && [[ -z "${TARGET_ROOT%/}" || "${TARGET_ROOT%/}" == "/" ]]; then
      node="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("node",""))' "$CONFIG_PATH" 2>/dev/null || true)"
      peers="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("peers") or {}))' "$CONFIG_PATH" 2>/dev/null || true)"
      log_info "nó='${node}' peers=${peers:-?}"
    fi
  else
    log_warn "config AUSENTE (${CONFIG_PATH})"
    rc=1
  fi
  if [[ -f "$UNIT_PATH" ]]; then
    log_info "unit: ${UNIT_PATH}"
  else
    log_warn "unit AUSENTE (${UNIT_PATH})"
    rc=1
  fi
  exit $rc
fi

# ---------------------------------------------------------------------------
# Validações (erro do USUÁRIO = exit 2; nada de default derrubando o build)
# ---------------------------------------------------------------------------
[[ -f "$SRC" ]] || { log_error "não encontrei ${SRC} (este script mora ao lado do ai_talk.py)"; exit 1; }

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || { log_error "porta inválida: '${PORT}'"; exit 2; }

if ! [[ "$BIND_ADDR" =~ ^[0-9.]+$ || "$BIND_ADDR" == "::" ]]; then
  log_error "endereço de escuta inválido: '${BIND_ADDR}' (use um IP ou 0.0.0.0)"
  exit 2
fi
if [[ "$BIND_ADDR" == "0.0.0.0" ]]; then
  log_warn "escutando em 0.0.0.0 (todas as interfaces). Numa máquina exposta,"
  log_warn "  prefira --bind com o IP da LAN (docs/CHAT.md §7)."
fi

# Nome do nó: padrão é o hostname, que desde o ADR-002 já é `ai-inference`/
# `ai-builder` numa ISO com papel concreto. Sem hostname (container), avisa.
if [[ -z "$NODE" ]]; then
  NODE="$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
  NODE="${NODE%%$'\n'*}"
fi
if [[ -z "$NODE" ]]; then
  log_error "não consegui determinar o nome do nó; use --node NAME"
  exit 2
fi
if ! [[ "$NODE" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  log_error "nome de nó inválido: '${NODE}' (minúsculas, dígitos e '-')"
  exit 2
fi

case "$ROLE" in
  auto|inference|builder) ;;
  *) log_error "papel inválido: '${ROLE}' (auto|inference|builder)"; exit 2 ;;
esac

# Um peer com o MESMO nome do nó é quase sempre erro de digitação (o nó
# tentaria falar consigo mesmo e a mensagem apareceria duplicada no log).
for i in "${!PEER_NAMES[@]}"; do
  if [[ "${PEER_NAMES[$i]}" == "$NODE" ]]; then
    log_error "peer '${PEER_NAMES[$i]}' tem o mesmo nome do nó (${NODE})."
    exit 2
  fi
done

# ---------------------------------------------------------------------------
# Chaves: ler, validar permissão e casar com os peers
# ---------------------------------------------------------------------------
# A chave é hexadecimal de 32 bytes (64 caracteres). Aceitar qualquer coisa
# "por flexibilidade" só adiaria o erro para o primeiro `send`.
KEY_HEX=""
if [[ -n "$KEY_FILE" ]]; then
  [[ -f "$KEY_FILE" ]] || { log_error "chave não encontrada: ${KEY_FILE}"; exit 2; }
  KEY_HEX="$(tr -d '[:space:]' < "$KEY_FILE")"
  [[ "$KEY_HEX" =~ ^[0-9a-fA-F]{64}$ ]] \
    || { log_error "chave inválida: ${KEY_FILE} (esperado 64 caracteres hex = 32 bytes)"; exit 2; }
  perms="$(stat -c '%a' "$KEY_FILE" 2>/dev/null || echo '000')"
  if (( (8#$perms & 8#004) != 0 )); then
    log_error "chave legível por 'outros' (modo ${perms}): ${KEY_FILE} — use chmod 640"
    exit 2
  fi
fi

KEYDIR_KEYS=()
if [[ -n "$KEYDIR" ]]; then
  [[ -d "$KEYDIR" ]] || { log_error "--keydir não é um diretório: ${KEYDIR}"; exit 2; }
  shopt -s nullglob
  for f in "$KEYDIR"/*.key; do
    name="$(basename "$f" .key)"
    hex="$(tr -d '[:space:]' < "$f")"
    [[ "$hex" =~ ^[0-9a-fA-F]{64}$ ]] \
      || { log_error "chave inválida: ${f} (esperado 64 caracteres hex)"; exit 2; }
    perms="$(stat -c '%a' "$f")"
    if (( (8#$perms & 8#004) != 0 )); then
      log_error "chave legível por 'outros' (modo ${perms}): ${f} — use chmod 640"
      exit 2
    fi
    KEYDIR_KEYS+=("${name}:${f}")
  done
  shopt -u nullglob
  # Chave por nó só vale para um peer que exista: uma chave órfã é um erro de
  # configuração que passaria calado (o receptor simplesmente não acharia nada).
  for entry in "${KEYDIR_KEYS[@]:-}"; do
    [[ -n "$entry" ]] || continue
    name="${entry%%:*}"
    found=0
    for i in "${!PEER_NAMES[@]}"; do
      [[ "${PEER_NAMES[$i]}" == "$name" ]] && found=1
    done
    if [[ $found -eq 0 ]]; then
      log_warn "chave em ${KEYDIR}/${name}.key sem peer '${name}' correspondente (ignorada na config)."
    fi
  done
fi

# ---------------------------------------------------------------------------
# Peers do arquivo (uma linha "nome=ip" por nó; # e linha vazia ignoradas)
# ---------------------------------------------------------------------------
# O arquivo é a BASE e o `--peer` é a EXCEÇÃO — a exceção vence **independente
# da ordem** na linha de comando. Fazer "o último vence" seria surpreendente:
# `--peers-file frota.txt --peer x=1.2.3.4` e `--peer x=1.2.3.4 --peers-file
# frota.txt` dariam resultados diferentes, e o erro apareceria só como um IP
# errado no alvo.
EXPLICIT_NAMES=("${PEER_NAMES[@]:-}")
EXPLICIT_ADDRS=("${PEER_ADDRS[@]:-}")
PEER_NAMES=()
PEER_ADDRS=()

is_explicit() {
  local want="$1" i
  for i in "${!EXPLICIT_NAMES[@]}"; do
    [[ -n "${EXPLICIT_NAMES[$i]}" && "${EXPLICIT_NAMES[$i]}" == "$want" ]] && return 0
  done
  return 1
}

if [[ -n "$PEERS_FILE" ]]; then
  [[ -f "$PEERS_FILE" ]] || { log_error "arquivo de frota não encontrado: ${PEERS_FILE}"; exit 2; }
  lineno=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [[ -z "$line" ]] && continue
    [[ "$line" == *=* ]] || { log_error "${PEERS_FILE}:${lineno}: esperado nome=ip (recebi '${raw}')"; exit 2; }
    name="${line%%=*}"
    if is_explicit "$name"; then
      log_info "peer '${name}': o --peer explícito vence o arquivo da frota."
      continue
    fi
    add_peer "$line"
  done < "$PEERS_FILE"
fi

for i in "${!EXPLICIT_NAMES[@]}"; do
  [[ -n "${EXPLICIT_NAMES[$i]}" ]] || continue
  add_peer "${EXPLICIT_NAMES[$i]}=${EXPLICIT_ADDRS[$i]}"
done

if (( ${#PEER_NAMES[@]} > MAX_PEERS )); then
  log_error "${#PEER_NAMES[@]} peers excedem o teto de ${MAX_PEERS} (ADR-005)."
  log_error "Acima disso é preciso relay/hub — ver docs/CHAT.md §5.2."
  exit 2
fi

HAVE_KEY=0
[[ -n "$KEY_HEX" || ${#KEYDIR_KEYS[@]} -gt 0 ]] && HAVE_KEY=1

log_info "nó='${NODE}' papel='${ROLE}' porta=${PORT} bind=${BIND_ADDR} peers=${#PEER_NAMES[@]}"
if [[ $HAVE_KEY -eq 0 ]]; then
  log_warn "NENHUMA chave informada (nem --key-file nem --keydir)."
  log_warn "  O serviço será instalado DESABILITADO: um canal sem HMAC não"
  log_warn "  autentica ninguém, e não existe chave default (docs/CHAT.md §9)."
  ENABLE_SERVICE=0
fi

# Confirmação só quando há algo destrutivo/ativo (é idempotente, mas habilitar
# um serviço de rede merece um aviso em terminal interativo).
if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 && $ENABLE_SERVICE -eq 1 \
      && -t 0 && "$(p '')" == "" ]]; then
  printf 'Habilitar e iniciar ai-talk.service agora? [s/N] '
  read -r answer
  case "$answer" in
    s|S|y|Y|sim|SIM) ;;
    *) log_warn "Cancelado pelo usuário (nada foi alterado)."; exit 0 ;;
  esac
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log_info "[dry-run] criaria ${ETC_DIR}/ (0750 root:${SVC_GROUP})"
  log_info "[dry-run] escreveria ${CONFIG_PATH} (0640) com ${#PEER_NAMES[@]} peer(s)"
  [[ -n "$KEY_HEX" ]]  && log_info "[dry-run] copiaria a chave global para ${KEY_COPY} (0640)"
  (( ${#KEYDIR_KEYS[@]} > 0 )) && log_info "[dry-run] copiaria ${#KEYDIR_KEYS[@]} chave(s) por nó para ${KEYS_DIR}/ (0640)"
  [[ -n "$PEERS_FILE" ]] && log_info "[dry-run] copiaria ${PEERS_FILE} para ${PEERS_COPY} (0640)"
  log_info "[dry-run] instalaria ${BIN_PATH} e ${LIB_PY}"
  log_info "[dry-run] escreveria ${UNIT_PATH}"
  if [[ $ENABLE_SERVICE -eq 1 ]]; then
    log_info "[dry-run] useradd --system ${SVC_USER} (se não existir) + systemctl enable --now ai-talk"
  else
    log_info "[dry-run] NÃO habilitaria o serviço (sem chave ou --no-service)"
  fi
  log_ok "[dry-run] nada foi alterado."
  exit 0
fi

# ---------------------------------------------------------------------------
# Usuário de sistema e diretórios
# ---------------------------------------------------------------------------
# Com `--root` NÃO mexemos em usuários/serviços do sistema em execução: os
# arquivos ficam com root:root e o dono real é acertado quando o alvo bootar
# (o próprio install.sh roda de novo lá, ver build.sh etapa 2.5).
SYS_MODE=1
if [[ "${TARGET_ROOT%/}" != "" && "${TARGET_ROOT%/}" != "/" ]]; then
  SYS_MODE=0
  log_info "modo --root ${TARGET_ROOT}: sem useradd/systemctl (só arquivos)."
fi

if [[ $SYS_MODE -eq 1 ]]; then
  if ! getent group "$SVC_GROUP" >/dev/null 2>&1; then
    groupadd --system "$SVC_GROUP"
    log_info "grupo de sistema '${SVC_GROUP}' criado"
  fi
  if ! getent passwd "$SVC_USER" >/dev/null 2>&1; then
    # --no-create-home: o serviço só precisa de StateDirectory/RuntimeDirectory
    # (o systemd cria e chowna). Um home para um daemon é superfície à toa.
    useradd --system --gid "$SVC_GROUP" --no-create-home \
            --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
    log_info "usuário de sistema '${SVC_USER}' criado"
  fi
fi

install -d -m 0750 "$ETC_DIR"
install -d -m 0750 "$KEYS_DIR"
install -d -m 0750 "$LIB_DIR"
install -d -m 0755 "$(dirname "$BIN_PATH")"
install -d -m 0755 "$(dirname "$LIB_PY")"
install -d -m 0755 "$(dirname "$UNIT_PATH")"

# ---------------------------------------------------------------------------
# Binário e biblioteca
# ---------------------------------------------------------------------------
install -m 0644 "$SRC" "$LIB_PY"
# O wrapper é um arquivo GERADO (não um link para /opt): o /opt pode não
# existir numa instalação manual, e um shebang python3 resolve a dependência.
tmp_bin="$(mktemp)"
cat > "$tmp_bin" <<'WRAPPER'
#!/usr/bin/env python3
"""Wrapper do ai-talk — carrega a implementação de /usr/local/lib/ai-talk."""
import os
import runpy
import sys

sys.argv[0] = "ai-talk"
runpy.run_path(
    os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))),
                 "lib", "ai-talk", "ai_talk.py"),
    run_name="__main__",
)
WRAPPER
install -m 0755 "$tmp_bin" "$BIN_PATH"
rm -f "$tmp_bin"
log_ok "binário instalado em ${BIN_PATH}"

# ---------------------------------------------------------------------------
# Chaves (copiadas, nunca geradas aqui)
# ---------------------------------------------------------------------------
if [[ -n "$KEY_HEX" ]]; then
  printf '%s\n' "$KEY_HEX" > "$KEY_COPY"
  chmod 0640 "$KEY_COPY"
  log_ok "chave global instalada em ${KEY_COPY} (0640)"
fi
for entry in "${KEYDIR_KEYS[@]:-}"; do
  [[ -n "$entry" ]] || continue
  name="${entry%%:*}"; src="${entry#*:}"
  dest="${KEYS_DIR}/${name}.key"
  # Só copia a chave de um peer CONHECIDO: uma chave órfã em /etc só aumenta a
  # superfície (e o aviso já foi dado acima).
  known=0
  for i in "${!PEER_NAMES[@]}"; do
    [[ "${PEER_NAMES[$i]}" == "$name" ]] && known=1
  done
  [[ $known -eq 1 ]] || continue
  install -m 0640 "$src" "$dest"
done
if [[ ${#KEYDIR_KEYS[@]} -gt 0 ]]; then
  log_ok "chaves por nó instaladas em ${KEYS_DIR}/"
fi
if [[ -n "$PEERS_FILE" ]]; then
  install -m 0640 "$PEERS_FILE" "$PEERS_COPY"
  log_ok "arquivo da frota instalado em ${PEERS_COPY} (0640)"
fi

# ---------------------------------------------------------------------------
# config.json — gerado AQUI e validado ANTES de habilitar o serviço
# ---------------------------------------------------------------------------
# Montar o JSON em Python (e não com printf/heredoc) evita o clássico "vírgula
# sobrando" e escapa nomes de forma correta. É stdlib e já é dependência.
CFG_ARGS=(--node "$NODE" --role "$ROLE" --port "$PORT" --bind "$BIND_ADDR"
          --out "$CONFIG_PATH")
[[ -n "$KEY_HEX" ]] && CFG_ARGS+=(--global-key "$KEY_COPY_CFG")
[[ -f "$PEERS_COPY" ]] && CFG_ARGS+=(--peers-file "$PEERS_COPY")
(( ${#PEER_NAMES[@]} > 0 )) && {
  for i in "${!PEER_NAMES[@]}"; do
    CFG_ARGS+=(--peer "${PEER_NAMES[$i]}=${PEER_ADDRS[$i]}")
  done
}
# A chave por nó é passada EXPLICITAMENTE (nome + caminho do ALVO). Antes o
# gerador a descobria testando `os.path.isfile(keys/<nome>.key)` — e com
# `--root` o caminho é prefixado, então o teste falhava e o peer saía sem
# chave: o nó cairia na chave global sem ninguém notar.
for entry in "${KEYDIR_KEYS[@]:-}"; do
  [[ -n "$entry" ]] || continue
  name="${entry%%:*}"
  known=0
  for i in "${!PEER_NAMES[@]}"; do
    [[ "${PEER_NAMES[$i]}" == "$name" ]] && known=1
  done
  [[ $known -eq 1 ]] || continue
  CFG_ARGS+=(--peer-key "${name}=${KEYS_DIR_CFG}/${name}.key")
done

python3 - "${CFG_ARGS[@]}" <<'PY'
import argparse, json, os, sys

ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("--node", required=True)
ap.add_argument("--role", default="auto")
ap.add_argument("--port", type=int, default=7331)
ap.add_argument("--bind", default="0.0.0.0")
ap.add_argument("--out", required=True)
ap.add_argument("--global-key", default="")
ap.add_argument("--peers-file", default="")
ap.add_argument("--peer-key", action="append", default=[])
ap.add_argument("--peer", action="append", default=[])
args = ap.parse_args()

peers = {}
# O arquivo da frota vem primeiro: uma flag --peer depois REFINA (vence), o que
# é o comportamento esperado de "fonte + exceção".
if args.peers_file and os.path.exists(args.peers_file):
    with open(args.peers_file, encoding="utf-8") as fh:
        for line in fh:
            line = line.split("#", 1)[0].strip()
            if not line or "=" not in line:
                continue
            name, _, addr = line.partition("=")
            peers[name.strip()] = addr.strip()
for spec in args.peer:
    name, _, addr = spec.partition("=")
    peers[name.strip()] = addr.strip()

for spec in args.peer_key:
    name, _, path = spec.partition("=")
    name = name.strip()
    if name not in peers:
        continue
    addr = peers[name] if isinstance(peers[name], str) else peers[name]["addr"]
    peers[name] = {"addr": addr, "key_file": path.strip()}

# Forma OBJETO sempre (o contrato aceita a string como atalho, mas uma config
# gerada pelo projeto não deve ter dois formatos: quem for lê-la — humano ou
# agente — não precisa saber que existe um caso especial).
for name, value in list(peers.items()):
    if isinstance(value, str):
        peers[name] = {"addr": value}

cfg = {
    "node": args.node,
    "role": args.role,
    "listen": {"address": args.bind, "port": args.port},
    "control_socket": "/run/ai-talk/control.sock",
    "peers": peers,
    "log": {"path": "/var/lib/ai-talk/messages.jsonl",
            "max_bytes": 33554432, "keep": 5,
            "control": False, "fsync": "always", "fsync_interval_ms": 100},
    "limits": {"max_frame_bytes": 16384, "max_body_bytes": 8192,
               "dedupe_window": 8192, "max_out_per_sec": 120},
    "timing": {"min_interval_ms": 50, "queue_max": 256,
               "send_timeout_ms": 15000, "connect_timeout_ms": 1000,
               "ack_timeout_ms": 2000, "max_attempts": 3,
               "backoff_ms": [1000, 2000], "tail_poll_ms": 250},
    "agent": {"enabled": False},
}
if args.global_key:
    cfg["key_file"] = args.global_key

os.makedirs(os.path.dirname(args.out), exist_ok=True)
tmp = args.out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(cfg, fh, indent=2, sort_keys=False)
    fh.write("\n")
os.chmod(tmp, 0o640)
os.replace(tmp, args.out)
PY

chmod 0640 "$CONFIG_PATH"
if [[ $SYS_MODE -eq 1 ]]; then
  chown -R "root:${SVC_GROUP}" "$ETC_DIR"
  chown -R "${SVC_USER}:${SVC_GROUP}" "$LIB_DIR"
fi
log_ok "config escrita em ${CONFIG_PATH} (0640)"

# Validação REAL: é o próprio daemon que vai ler isso. Se ele recusar, não
# adianta habilitar o serviço (o systemd entraria em loop de restart).
if [[ $SYS_MODE -eq 1 ]]; then
  if ! "$BIN_PATH" check-config --config "$CONFIG_PATH" >/tmp/ai-talk-check.$$ 2>&1; then
    log_error "o próprio ai-talk RECUSOU a config gerada:"
    sed 's/^/  /' /tmp/ai-talk-check.$$ >&2
    rm -f /tmp/ai-talk-check.$$
    log_error "Isso é bug do install.sh — o serviço NÃO será habilitado."
    exit 1
  fi
  rm -f /tmp/ai-talk-check.$$
  log_ok "config validada pelo ai-talk (check-config)"
else
  # `--root`: o binário instalado importa de /usr/local/lib, que não existe
  # NESTA máquina. Validamos a ESTRUTURA com o `load_config` do módulo do
  # repositório — é o mesmo código que o daemon vai usar no alvo (pega porta
  # inválida, peer sem addr, teto de 15…), só não lê as chaves.
  if ! python3 - "$SRC" "$CONFIG_PATH" <<'PYCHK'
import importlib.util, sys
src, cfg_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ai_talk", src)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    cfg = mod.load_config(cfg_path)
except mod.ConfigError as exc:
    print(f"config inválida: {exc}", file=sys.stderr)
    sys.exit(1)
print(f"config OK (estrutura): node={cfg['node']} peers={len(cfg['peers'])}")
PYCHK
  then
    log_error "a config gerada é inválida para o próprio ai-talk (bug do install.sh)."
    exit 1
  fi
  log_ok "config validada (estrutura, modo --root)"
fi

# ---------------------------------------------------------------------------
# Unit do systemd
# ---------------------------------------------------------------------------
install -m 0644 "${SCRIPT_DIR}/ai-talk.service" "$UNIT_PATH"
log_ok "unit escrita em ${UNIT_PATH}"

if [[ $ENABLE_SERVICE -eq 0 ]]; then
  log_warn "serviço NÃO habilitado (sem chave ou --no-service)."
  log_warn "  Quando tiver a chave, rode de novo:"
  log_warn "    sudo bash talk/install.sh --node ${NODE} --key-file <chave> [--peer ...]"
  exit 0
fi

if [[ $SYS_MODE -eq 0 ]]; then
  log_info "modo --root: habilitação do serviço fica para o 1º boot do alvo."
  exit 0
fi

systemctl daemon-reload
systemctl enable ai-talk.service >/dev/null
log_ok "ai-talk.service habilitado"

if [[ $START_SERVICE -eq 1 ]]; then
  if systemctl restart ai-talk.service; then
    sleep 1
    if systemctl is-active --quiet ai-talk.service; then
      log_ok "ai-talk.service ativo (porta ${PORT})"
    else
      log_error "ai-talk.service NÃO está ativo. Veja: journalctl -u ai-talk -n 40"
      exit 1
    fi
  else
    log_error "falha ao iniciar ai-talk.service (journalctl -u ai-talk -n 40)"
    exit 1
  fi
fi

log_ok "instalação do ai-talk concluída."
