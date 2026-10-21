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
# Rede do sistema DESTA máquina (make network-fix) — ver mods/network/
NET_MODE ?= auto
NET_IFACE ?=
NET_IP   ?=
NET_GW   ?=
FAMILY   ?= auto
# ISO a verificar/bootar (make iso-verify ISO=... / make iso-vm ISO=...)
ISO      ?=
# Args extras para o build da ISO (ex.: ISO_ARGS=--serial-console)
ISO_ARGS ?=
# Args extras para o teste de VM (ex.: VM_ARGS="--boot-mode uefi")
VM_ARGS  ?=
# Dispositivo alvo do pendrive (make pendrive DEVICE=/dev/sdb). NÃO tem padrão
# de propósito: sem DEVICE explícito, `make pendrive` só explica o uso.
DEVICE   ?=
# Args extras do gravador (ex.: PENDRIVE_ARGS=--dry-run / --no-verify)
PENDRIVE_ARGS ?=
# Backend de GPU (opcional, EXPLÍCITO): make build GPU=vulkan  → ver docs/GPU.md
GPU      ?=
JOBS     ?= 4
LLAMA_REF ?= master
IMAGE    ?= ai-cpu-os-llama:local

SCRIPTS := $(shell find . -name '*.sh' -not -path './.git/*' | sort)

.PHONY: help lint bashn shellcheck python yaml docs validate dry-run apply \
        build mods mods-check mods-test families families-test avx512-test gpu-check \
        iso iso-dry-run iso-lint iso-yaml iso-verify iso-vm \
        iso-select-test iso-repo-test iso-verify-test iso-release-test \
        iso-space-test identity-test iso-chat-test talk-install-test ci-guards-test \
        iso-lock-test \
        pendrives pendrive pendrive-test iso-check iso-check-test \
        ui ui-test ui-page-test network-fix network-test apt-fix apt-test \
        talk-test talk-install-test iso-chat-test \
        docker docker-check ci clean

help: ## Lista os alvos disponíveis
	@printf '\n%balvos disponíveis:%b\n\n' '\033[36m' '\033[0m'
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[32m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\n%bDocs:%b README.md (usuário final) · README.technical.md (mantenedor) · AGENTS.md (regras)\n\n' '\033[36m' '\033[0m'

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
	@python3 -m compileall -q roles/ webui/ talk/ && echo "python: OK"

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
	         docs/FAMILIES.md docs/MODS.md docs/GPU.md \
	         docs/DECISIONS.md docs/CHAT.md \
	         docs/IMPLANTAR-EM-OUTRO-PC.md; do \
	  [[ -f "$$f" ]] || { echo "FALTANDO: $$f"; exit 1; }; \
	done; \
	echo "docs: OK"

validate: lint docs families-test avx512-test iso-select-test iso-repo-test iso-verify-test identity-test iso-chat-test ci-guards-test iso-lock-test iso-disk-test iso-release-test iso-space-test network-test apt-test pendrive-test iso-check-test ui-test ui-page-test talk-test talk-install-test iso-dry-run ## Lint + docs + famílias + AVX-512 + identidade + testes de ISO + rede + UI + chat + guardas + dry-run

dry-run: ## Simula a aplicação completa (nada é alterado)
	@sudo ./build.sh --role $(ROLE) --family $(FAMILY) --dry-run --yes --skip-tests

apply: ## Aplica o tuning de verdade (requer root; confirmação do build.sh)
	@sudo ./build.sh --role $(ROLE) --family $(FAMILY)

build: ## Compila o llama.cpp para a família detectada (FAMILY= força)
	@bash llama-build.sh --family $(FAMILY) --ref $(LLAMA_REF) --jobs $(JOBS) \
	  $(if $(GPU),--gpu $(GPU))

families: ## Lista as famílias de CPU suportadas
	@bash build.sh --list-families

families-test: ## Prova o casamento CPU→família (corpus; não precisa do hardware)
	@bash tests/test-families.sh

avx512-test: ## Prova a política de AVX-512 das famílias (não precisa do hardware)
	@bash tests/test-avx512-policy.sh

gpu-check: ## Relata as GPUs presentes e os backends disponíveis (só leitura)
	@bash llama-build.sh --gpu-check

mods: ## Lista as modificações portáveis (mods/)
	@bash mods/apply.sh list

mods-check: ## Confere os requisitos das mods neste sistema
	@bash mods/apply.sh check

mods-test: ## Testa as mods (sintaxe + dry-run idempotente em container)
	@bash mods/apply.sh test

iso: ## Gera a ISO (entregável final); requer DISK=/dev/xxx [ISO_ARGS=...]
	@if [ -z "$(DISK)" ]; then \
	  echo "Defina o disco alvo: make iso DISK=/dev/nvme0n1"; exit 1; \
	fi
	@bash iso/build-iso.sh --disk $(DISK) \
	  --role $(ROLE) --family $(FAMILY) $(ISO_ARGS)

iso-dry-run: ## Simula a geração da ISO (seguro, não baixa nada; igual ao CI)
	@set -euo pipefail; \
	bash iso/build-iso.sh --disk /dev/vda \
	  --role inference --family intel-broadwell --serial-console --dry-run >/dev/null; \
	echo "iso-dry-run: OK (ubuntu, sem flags extras)"

iso-yaml: ## Autoteste dos templates + das ferramentas da ISO (não gera ISO)
	@bash iso/build-iso.sh --check-templates --yes

iso-verify: ## Verifica uma ISO gerada: make iso-verify ISO=iso/out/x.iso
	@if [ -z "$(ISO)" ]; then \
	  echo "Defina a ISO: make iso-verify ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso"; \
	  exit 1; \
	fi
	@bash iso/verify-iso.sh --iso "$(ISO)" $(if $(DISK),--disk $(DISK))

iso-vm: ## Boota a ISO numa VM e espera instalação + 1º boot (requer qemu)
	@if [ -z "$(ISO)" ]; then \
	  echo "Defina a ISO: make iso-vm ISO=iso/out/ai-cpu-os-ubuntu-<data>.iso"; \
	  exit 1; \
	fi
	@bash iso/test-vm.sh --iso "$(ISO)" --yes $(VM_ARGS)

pendrives: ## Lista os dispositivos que podem receber a ISO (só leitura)
	@bash iso/write-pendrive.sh --list

pendrive: ## Grava a ISO num pendrive (DEVICE=/dev/sdX) — APAGA o dispositivo!
	@if [ -z "$(DEVICE)" ]; then \
	  echo "Informe o dispositivo: make pendrive DEVICE=/dev/sdb"; \
	  echo "Para ver o que está plugado: make pendrives"; \
	  exit 1; \
	fi
	@cmd='bash iso/write-pendrive.sh --device $(DEVICE)'; \
	 if [ -n "$(ISO)" ]; then cmd="$$cmd --iso $(ISO)"; fi; \
	 if [ -n "$(PENDRIVE_ARGS)" ]; then cmd="$$cmd $(PENDRIVE_ARGS)"; fi; \
	 if [ "$$(id -u)" -ne 0 ]; then cmd="sudo $$cmd"; fi; \
	 echo "+ $$cmd"; \
	 exec $$cmd

pendrive-test: ## Prova as travas do gravador de pendrive (sem root nem device)
	@bash tests/test-write-pendrive.sh

iso-check: ## Confere uma ISO BAIXADA (sem xorriso, sem root): make iso-check ISO=...
	@if [ -z "$(ISO)" ]; then \
	  echo "Defina a ISO: make iso-check ISO=~/Downloads/ai-cpu-os-ubuntu.iso"; \
	  exit 1; \
	fi
	@bash iso/check-iso.sh --iso "$(ISO)" $(ISO_CHECK_ARGS)

iso-check-test: ## Prova a conferência de ISO baixada (fixtures; sem xorriso)
	@bash tests/test-check-iso.sh

ui: ## Abre a interface web local (criar/conferir a ISO pelo navegador)
	@python3 webui/server.py $(UI_ARGS)

network-test: ## Prova a mod `network` numa árvore falsa (sem root, sem rede)
	@bash tests/test-network-mod.sh

iso-space-test: ## Prova que o verificador não quebra por falta de espaço (modelo de 2 GB)
	@bash tests/test-verify-iso-space.sh

iso-release-test: ## Prova a conferência de release do --iso-repo auto (ISOs falsas)
	@bash tests/test-iso-release.sh

apt-test: ## Prova a mod `apt-sources` numa árvore falsa (sem root, sem rede)
	@bash tests/test-apt-sources-mod.sh

apt-fix: ## Conserta o apt DESTA máquina (fontes que não existem); APT_DRY=1 simula
	@set -euo pipefail; args=(); \
	if [ -n "$(APT_DRY)" ]; then args+=(--dry-run); fi; \
	echo "sudo bash mods/apt-sources/apply.sh $${args[*]}"; \
	sudo bash mods/apt-sources/apply.sh $${args[@]+"$${args[@]}"}

network-fix: ## Conserta a rede DESTA máquina (DHCP); use NET_MODE/NET_IP/NET_GW
	@set -euo pipefail; args=(--mode "$(NET_MODE)"); \
	if [ -n "$(NET_IFACE)" ]; then args+=(--interface "$(NET_IFACE)"); fi; \
	if [ -n "$(NET_IP)" ];    then args+=(--ip "$(NET_IP)"); fi; \
	if [ -n "$(NET_GW)" ];    then args+=(--gateway "$(NET_GW)"); fi; \
	echo "sudo bash mods/network/apply.sh $${args[*]}"; \
	sudo bash mods/network/apply.sh "$${args[@]}"

ui-test: ## Prova a interface web (API + salvaguardas; sem navegador, sem rede)
	@bash tests/test-webui.sh

ui-page-test: ## Executa o JS da página num DOM falso (pega erro no topo do script)
	@bash tests/test-webui-page.sh

talk-test: ## Prova o contrato do ai-talk (loopback, sem rede externa, sem root)
	@bash tests/test-ai-talk.sh

talk-install-test: ## Prova o talk/install.sh (config, chaves, unit; via --root)
	@bash tests/test-ai-talk-install.sh

iso-chat-test: ## Prova o chat DENTRO da ISO (--chat-*, payload, os 3 elos)
	@bash tests/test-iso-chat.sh

iso-lock-test: ## Prova a trava de instância única do gerador de ISO (flock real)
	@bash tests/test-iso-lock.sh

identity-test: ## Prova a identidade derivada do papel: ai-inference/ai-builder (ADR-002)
	@bash tests/test-role-identity.sh

iso-disk-test: ## Prova o tratamento do disco do autoinstall (auto/inválido/ausente)
	@bash tests/test-iso-disk.sh

iso-lint: ## Verifica os scripts da ISO e valida templates + ferramentas
	@bash -n iso/build-iso.sh iso/verify-iso.sh iso/test-vm.sh iso/write-pendrive.sh \
	  iso/common/firstboot.sh
	@sh -n iso/common/late-command.sh
	@shellcheck -x -S warning iso/build-iso.sh iso/verify-iso.sh iso/test-vm.sh \
	  iso/write-pendrive.sh iso/common/late-command.sh
	@bash iso/build-iso.sh --check-templates --yes >/dev/null \
	  && echo "iso-lint: templates e ferramentas OK"
	@echo "iso-lint: OK"

iso-select-test: ## Prova a escolha da ISO oficial (SHA256SUMS reais; sem rede)
	@bash tests/test-iso-selection.sh

iso-repo-test: ## Prova o download do repo apt local (stubs; sem rede nem apt real)
	@bash tests/test-iso-repo-filter.sh

iso-verify-test: ## Prova o verificador da ISO (uma base só; sem xorriso nem rede)
	@bash tests/test-verify-iso-repo.sh

ci-guards-test: ## Prova que os guardas do CI REALMENTE derrubam o job (cópia temporária)
	@bash tests/test-ci-guards.sh

docker: ## Constrói a imagem de runtime localmente
	@docker build -f docker/Dockerfile -t $(IMAGE) .

docker-check: ## Lint do Dockerfile (não constrói a imagem)
	@docker buildx build --check -f docker/Dockerfile . || \
	 echo "buildx --check indisponível nesta versão do Docker"

ci: validate dry-run ## Reproduz localmente o que o workflow 'validate' faz
	@echo "ci: OK — lint + docs + famílias + dry-run passaram"

clean: ## Remove caches locais de build
	@find . -name '__pycache__' -type d -not -path './.git/*' -exec rm -rf {} + 2>/dev/null || true
	@echo "clean: OK"
