#!/usr/bin/env bash
#
# profiles/ryzen/build-runner.sh — Build + push de imagens para o registry local
# -----------------------------------------------------------------------------
# Lê um Dockerfile de um repositório, faz o docker build com cache (usando
# --cache-from do registry local) e faz push para localhost:5000.
#
# Uso:
#   bash profiles/ryzen/build-runner.sh --context /caminho/do/repo \
#                                       --tag localhost:5000/meu/app:1.0 \
#                                       [--dockerfile Dockerfile] \
#                                       [--cache-from localhost:5000/meu/app:latest] \
#                                       [--build-arg K=V] [--push] \
#                                       [--dry-run] [--yes]
#
# Idempotente: reusa cache; só faz push se --push for passado.
# -----------------------------------------------------------------------------

set -euo pipefail

DRY_RUN=0
ASSUME_YES=0
CONTEXT=""
TAG=""
DOCKERFILE="Dockerfile"
CACHE_FROM=""
DO_PUSH=0
BUILD_ARGS=()

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_INFO="\033[36m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_OK="\033[32m"
else
  C_RESET=""; C_INFO=""; C_WARN=""; C_ERR=""; C_OK=""
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_info()  { printf '%b[%s] [INFO ] %s%b\n' "$C_INFO" "$(_ts)" "$*" "$C_RESET"; }
log_warn()  { printf '%b[%s] [WARN ] %s%b\n' "$C_WARN" "$(_ts)" "$*" "$C_RESET" >&2; }
log_error() { printf '%b[%s] [ERROR] %s%b\n' "$C_ERR"  "$(_ts)" "$*" "$C_RESET" >&2; }
log_ok()    { printf '%b[%s] [OK   ] %s%b\n' "$C_OK"   "$(_ts)" "$*" "$C_RESET"; }

run() {
  local desc="$1"; shift
  if [[ $DRY_RUN -eq 1 ]]; then log_info "[dry-run] ${desc}: $*"; return 0; fi
  log_info "${desc}: $*"
  "$@"
}

confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then return 0; fi
  local reply; read -r -p "${prompt} [s/N] " reply
  [[ "$reply" =~ ^[sSyY]$ ]]
}

usage() {
  cat <<'EOF'
build-runner.sh — build + push para o registry local

Uso:
  build-runner.sh --context DIR --tag localhost:5000/nome:tag [opções]

Opções:
  --context DIR          Diretório de contexto do build (obrigatório).
  --tag REF              Tag da imagem (obrigatório; deve apontar p/ localhost:5000).
  --dockerfile ARQ       Nome do Dockerfile (padrão: Dockerfile).
  --cache-from REF       Imagem de cache (padrão: mesma tag com ':cache').
  --build-arg K=V        Argumento de build (repetível).
  --push                 Faz push ao registry local após o build.
  --dry-run              Simula, sem construir/publicar.
  --yes                  Não pede confirmação.
  -h | --help            Esta ajuda.
EOF
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_warn "Docker não encontrado (dry-run: continuando a simulação)."
      return 0
    fi
    log_error "Docker não encontrado. Rode: sudo bash profiles/ryzen/docker-setup.sh"
    exit 1
  fi
  if [[ $DRY_RUN -eq 0 ]] && ! docker info >/dev/null 2>&1; then
    log_error "Daemon Docker inacessível. Verifique: systemctl status docker"
    exit 1
  fi
}

validate_inputs() {
  [[ -n "$CONTEXT" ]] || { log_error "--context é obrigatório."; usage; exit 2; }
  [[ -n "$TAG" ]]     || { log_error "--tag é obrigatório."; usage; exit 2; }
  if [[ ! -d "$CONTEXT" ]]; then
    log_error "Contexto inexistente: ${CONTEXT}"; exit 1
  fi
  if [[ ! -f "${CONTEXT}/${DOCKERFILE}" ]]; then
    log_error "Dockerfile não encontrado: ${CONTEXT}/${DOCKERFILE}"; exit 1
  fi
  if [[ "$TAG" != localhost:* && "$TAG" != 127.0.0.1:* ]]; then
    log_warn "A tag '${TAG}' não aponta para o registry local (localhost:5000)."
    log_warn "Para publicar no registry privado, use: localhost:5000/<nome>:<tag>"
  fi
}

do_build() {
  local args=(build -f "${CONTEXT}/${DOCKERFILE}" -t "$TAG")

  # Cache: tenta puxar a imagem de cache do registry local (ignora falha).
  if [[ -n "$CACHE_FROM" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log_info "[dry-run] docker pull ${CACHE_FROM} (best-effort)"
    else
      log_info "Tentando puxar cache: ${CACHE_FROM}"
      docker pull "$CACHE_FROM" >/dev/null 2>&1 || log_warn "Sem cache remoto disponível (primeiro build?)."
    fi
    args+=(--cache-from "$CACHE_FROM")
  fi

  local ba
  for ba in "${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}"; do
    args+=(--build-arg "$ba")
  done

  args+=("$CONTEXT")

  run "docker build" docker "${args[@]}"
}

do_push() {
  if [[ $DO_PUSH -eq 0 ]]; then
    log_info "Push não solicitado (use --push)."
    return 0
  fi
  if ! confirm "Fazer push de '${TAG}' para o registry local?"; then
    log_warn "Push cancelado."
    return 0
  fi
  run "docker push" docker push "$TAG"
}

report() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log_info "[dry-run] docker images --filter reference='${TAG}'"
    return 0
  fi
  docker images --filter "reference=${TAG}" || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context)    [[ $# -ge 2 ]] || { log_error "--context exige valor"; exit 2; }; CONTEXT="$2"; shift 2 ;;
      --tag)        [[ $# -ge 2 ]] || { log_error "--tag exige valor"; exit 2; }; TAG="$2"; shift 2 ;;
      --dockerfile) [[ $# -ge 2 ]] || { log_error "--dockerfile exige valor"; exit 2; }; DOCKERFILE="$2"; shift 2 ;;
      --cache-from) [[ $# -ge 2 ]] || { log_error "--cache-from exige valor"; exit 2; }; CACHE_FROM="$2"; shift 2 ;;
      --build-arg)  [[ $# -ge 2 ]] || { log_error "--build-arg exige valor"; exit 2; }; BUILD_ARGS+=("$2"); shift 2 ;;
      --push)       DO_PUSH=1; shift ;;
      --dry-run)    DRY_RUN=1; shift ;;
      --yes)        ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *) log_error "Argumento desconhecido: $1"; usage; exit 2 ;;
    esac
  done

  require_docker
  validate_inputs

  # Default de cache: mesma tag, prefixo ':cache'.
  if [[ -z "$CACHE_FROM" ]]; then
    if [[ "$TAG" == *:* ]]; then
      CACHE_FROM="${TAG%:*}:cache"
    else
      CACHE_FROM="${TAG}:cache"
    fi
  fi

  log_info "=== build-runner.sh ==="
  log_info "Contexto:   ${CONTEXT}"
  log_info "Dockerfile: ${CONTEXT}/${DOCKERFILE}"
  log_info "Tag:        ${TAG}"
  log_info "Cache de:   ${CACHE_FROM}"

  do_build
  do_push
  report

  log_ok "build-runner.sh concluído."
  if [[ $DO_PUSH -eq 1 ]]; then
    log_info "Imagem publicada: ${TAG}"
    log_info "Consumo: docker run --rm ${TAG}"
  fi
}

main "$@"
