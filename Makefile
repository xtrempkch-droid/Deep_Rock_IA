# Conveniências locais — reproduz o que o CI faz.
#
# Uso:
#   make help          lista os alvos
#   make ci            roda lint + dry-run (igual ao workflow 'validate')
#   make build         compila o llama.cpp para a FAMÍLIA detectada
#   make build FAMILY=amd-zen2   força uma família
#   make mods          lista as modificações portáveis
#   make mods-check    confere os requisitos das mods neste sistema
#   make docker        constrói a imagem de runtime localmente

SHELL := /bin/bash
.DEFAULT_GOAL := help

ROLE     ?= auto
FAMILY   ?= auto
# Legado: usado apenas pelos alvos da ISO (cuja base ainda é Debian).
PROFILE  ?= auto
JOBS     ?= 4
LLAMA_REF ?= master
IMAGE    ?= ai-cpu-os-llama:local

SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' | sort)

.PHONY: help lint bashn shellcheck python yaml docs validate dry-run apply \
        build mods mods-check mods-test iso iso-dry-run iso-lint \
        docker docker-check ci clean families

help: ## Lista os alvos disponíveis
	@printf '\n%balvos disponíveis:%b\n\n' '\033[36m' '\033[0m'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[32m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

lint: bashn shellcheck python yaml iso-lint ## Lint completo (bash, shellcheck, python, yaml, iso)

bashn: ## Verifica a sintaxe de todos os scripts (bash -n)
	@set -euo pipefail; \
	for f in $(SCRIPTS); do bash -n "$$f"; done; \
	echo "bash -n: $(words $(SCRIPTS)) scripts OK"

shellcheck: ## Roda shellcheck (severidade warning+)
	@command -v shellcheck >/dev/null || { echo "shellcheck ausente: https://www.shellcheck.net"; exit 1; }
	@shellcheck -x -S warning $(SCRIPTS)
	@echo "shellcheck: OK"

python: ## Compila os arquivos Python (checagem de sintaxe)
	@python3 -m compileall -q roles/ && echo "python: OK"

yaml: ## Lint dos arquivos YAML
	@command -v yamllint >/dev/null || { echo "yamllint ausente"; exit 1; }
	@yamllint -c .yamllint.yml .github/ docker/ roles/
	@echo "yamllint: OK"

docs: ## Verifica se os documentos obrigatórios existem
	@set -euo pipefail; \
	for f in README.md AGENTS.md LICENSE docs/ROADMAP.md docs/ARCHITECTURE.md \
	         docs/STATE.md docs/HARDWARE.md docs/TUNING.md \
	         docs/TROUBLESHOOTING.md docs/TUTORIAL.md docs/CI.md \
	         docs/VALIDATION.md docs/ISO.md docs/JOURNAL.md \
	         docs/FAMILIES.md docs/MODS.md; do \
	  [[ -f "$$f" ]] || { echo "FALTANDO: $$f"; exit 1; }; \
	done; \
	echo "docs: OK"

validate: lint docs ## Lint + presença dos documentos

dry-run: ## Simula a aplicação completa (nada é alterado)
	@sudo ./build.sh --role $(ROLE) --family $(FAMILY) --dry-run --yes --skip-tests

apply: ## Aplica o tuning de verdade (requer root; confirmação do build.sh)
	@sudo ./build.sh --role $(ROLE) --family $(FAMILY)

build: ## Compila o llama.cpp para a família detectada (FAMILY= força)
	@bash llama-build.sh --family $(FAMILY) --ref $(LLAMA_REF) --jobs $(JOBS)

families: ## Lista as famílias de CPU suportadas
	@bash build.sh --list-families

mods: ## Lista as modificações portáveis (mods/)
	@bash mods/apply.sh list

mods-check: ## Confere os requisitos das mods neste sistema
	@bash mods/apply.sh check

mods-test: ## Testa as mods (sintaxe + dry-run idempotente em container)
	@bash mods/apply.sh test

iso: ## Gera a ISO de instalação (entregável final); requer DISK=/dev/xxx
	@if [ -z "$(DISK)" ]; then \
	  echo "Defina o disco alvo: make iso DISK=/dev/nvme0n1"; exit 1; \
	fi
	@bash iso/build-iso.sh --disk $(DISK) --profile $(PROFILE)

iso-dry-run: ## Simula a geração da ISO (seguro, não baixa nada pesado)
	@bash iso/build-iso.sh --disk "$(or $(DISK),/dev/nvme0n1)" --profile $(PROFILE) --dry-run

iso-lint: ## Verifica os scripts da ISO (bash -n + shellcheck)
	@bash -n iso/build-iso.sh iso/preseed/firstboot.sh
	@sh -n iso/preseed/late-command.sh
	@shellcheck -x -S warning iso/build-iso.sh iso/preseed/late-command.sh
	@echo "iso-lint: OK"

docker: ## Constrói a imagem de runtime localmente
	@docker build -f docker/Dockerfile -t $(IMAGE) .

docker-check: ## Lint do Dockerfile (não constrói a imagem)
	@docker buildx build --check -f docker/Dockerfile . || \
	 echo "buildx --check indisponível nesta versão do Docker"

ci: validate dry-run ## Reproduz localmente o que o workflow 'validate' faz
	@echo "ci: OK — lint + dry-run passaram"

clean: ## Remove caches locais de build
	@find . -name '__pycache__' -type d -not -path './.git/*' -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
