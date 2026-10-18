# ROADMAP — ai-cpu-os

> Documento vivo. Atualizado a cada mudança de estado.
> **Última atualização:** 2026-10-12

Legenda de status: ✅ Concluído · 🔄 Em Progresso · ⏳ Planejado · 💡 Ideia

Formato dos itens: `[status] Descrição — início: AAAA-MM-DD · responsável: <nome/IA>`

---

## ✅ Concluído

| Item                                                                 | Início     | Conclusão  |
|----------------------------------------------------------------------|------------|------------|
| Estrutura inicial do repositório (pastas, LICENSE MIT)               | 2026-10-07 | 2026-10-07 |
| `README.md` com filosofia, tabela de hardware, uso e avisos           | 2026-10-07 | 2026-10-07 |
| `AGENTS.md` (memória para IAs)                                        | 2026-10-07 | 2026-10-07 |
| `docs/ROADMAP.md`, `ARCHITECTURE.md`, `STATE.md`                      | 2026-10-07 | 2026-10-07 |
| `docs/HARDWARE.md`, `TUNING.md`, `TROUBLESHOOTING.md`                 | 2026-10-07 | 2026-10-07 |
| `build.sh` — orquestrador com `--role`/`--family`, `--dry-run`, `--yes` | 2026-10-07 | 2026-10-07 |
| `detect-hardware.sh` — detecção de CPU/RAM/canal/disco                | 2026-10-07 | 2026-10-07 |
| `mods/kernel-tuning/kernel-tuning.sh`, `hugepages.sh`, `governor.sh`              | 2026-10-07 | 2026-10-07 |
| `roles/inference/*` (install, llama-build, sysctl, shell-ia, service)   | 2026-10-07 | 2026-10-07 |
| `roles/builder/*` (install, docker, registry, gitea, build-runner)   | 2026-10-07 | 2026-10-07 |
| `tests/smoke-test.sh`                                                 | 2026-10-07 | 2026-10-07 |
| `docs/TUTORIAL.md` — tutorial explicado do zero + diretriz de `AGENTS.md` | 2026-10-07 | 2026-10-07 |
| CI/CD: `validate.yml` (lint + dry-run + guarda-corpo das regras)        | 2026-10-07 | 2026-10-07 |
| CI/CD: `build-llama.yml` (compila por perfil + inferência de prova + Release) | 2026-10-07 | 2026-10-07 |
| CI/CD: `container.yml` + `docker/Dockerfile` (imagem no GHCR)            | 2026-10-07 | 2026-10-07 |
| `Makefile`, `docs/CI.md`, templates de issue/PR, Dependabot              | 2026-10-07 | 2026-10-07 |
| Lint limpo: `shellcheck -S warning` sem avisos em todos os scripts       | 2026-10-07 | 2026-10-07 |
| 1º run do CI no GitHub: `validate` ✅ (4/4 jobs)                          | 2026-10-07 | 2026-10-07 |
| `build-llama` executado no GitHub: 2 perfis compilados + inferência real (6m04s) | 2026-10-07 | 2026-10-07 |
| Imagem publicada no GHCR (`container` ✅ em `main` e na tag)              | 2026-10-07 | 2026-10-07 |
| Release `ai-cpu-os v0.2.0` com os binários `.tar.gz` dos dois perfis      | 2026-10-07 | 2026-10-07 |
| Correção do bug de RPATH na imagem Docker (achado pelo CI: `exit 127`)    | 2026-10-07 | 2026-10-07 |
| Protocolo de testes em hardware: `docs/VALIDATION.md` (blocos A–L)        | 2026-10-07 | 2026-10-07 |
| **ISO de instalação:** `iso/build-iso.sh` + preseed + serviço de 1º boot + `docs/ISO.md` | 2026-10-07 | 2026-10-07 |
| `docs/JOURNAL.md` — diário de sessões e continuidade (Regra 14) + "Retomada rápida" | 2026-10-07 | 2026-10-07 |
| Unificação do hardware: Xeon = **quad channel** (era "dual" em alguns docs) | 2026-10-07 | 2026-10-07 |
| **`families/` — suporte por FAMÍLIA de CPU com herança** (8 famílias + `resolve.sh` + política de AVX-512 `never`/`optin`/`auto`) | 2026-10-12 | 2026-10-12 |
| **`roles/` — papéis separados do hardware** (`inference`, `builder`) substituindo `roles/inference` e `roles/builder` | 2026-10-12 | 2026-10-12 |
| **`mods/` — modificações portáveis** (motor `list/info/check/apply/revert/test`, conjuntos `system`/`portable`, 4 mods com `revert`) | 2026-10-12 | 2026-10-12 |
| `llama-build.sh` único, dirigido pela família, com padrão **portátil** (`GGML_NATIVE=OFF`) e `--assume-family-isa` para cross-build | 2026-10-12 | 2026-10-12 |
| Correção do **bug latente de portabilidade do CI** (`GGML_NATIVE=ON` no runner → risco de `SIGILL` no alvo) | 2026-10-12 | 2026-10-12 |
| `docs/FAMILIES.md` + `docs/MODS.md` + `mods/README.md` + `roles/README.md` | 2026-10-12 | 2026-10-12 |
| Sistema operacional de referência passou a **Ubuntu Server** | 2026-10-12 | 2026-10-12 |
| Comentários de instrução do usuário no README **aplicados e removidos** | 2026-10-12 | 2026-10-12 |
| **ISO em base Ubuntu Server** — `--distro ubuntu` (padrão) + `iso/autoinstall/autoinstall.yaml` + remontagem por `-indev/-outdev -map` (setores de boot preservados) | 2026-10-12 | 2026-10-12 |
| `late-command.sh` **compartilhado** entre debian-installer e Subiquity (`AI_CURTIN=1`); flags `--role`/`--family` também na ISO | 2026-10-12 | 2026-10-12 |
| **Autoteste dos templates da ISO** (`--check-templates` / `make iso-yaml`): valida tokens, sintaxe e o `autoinstall.yaml` **substituído** com `yamllint` — rodando no CI | 2026-10-12 | 2026-10-12 |
| **`iso/verify-iso.sh`** — verificação de *conteúdo* da ISO, com modo `--dir` que dispensa `xorriso` (por isso é exercitado no CI, com teste negativo) | 2026-10-12 | 2026-10-12 |
| **`iso/test-vm.sh`** — teste de *comportamento*: boota a ISO em qemu e espera instalação + 1º boot por marcadores no console serial | 2026-10-12 | 2026-10-12 |
| `--serial-console` (console ttyS0 na ISO **e** no sistema instalado) torna a instalação e o 1º boot observáveis sem tela | 2026-10-12 | 2026-10-12 |
| O build passa a **verificar a ISO automaticamente** ao final; `make iso-verify` e `make iso-vm` | 2026-10-12 | 2026-10-12 |
| **Corpus de CPUs reais** (`tests/families-matrix.txt` + `tests/test-families.sh`) provando o casamento CPU → família no CI — é como Zen 3/Zen 4 são exercitados **sem o hardware** | 2026-10-12 | 2026-10-12 |
| Correção de **10 modelos mal atribuídos** achados pelo corpus: nenhum EPYC casava e a série Ryzen 8000 (Zen 4) caía em `generic` | 2026-10-12 | 2026-10-12 |
| `build-llama` do CI passou a compilar também para `amd-zen3`, `amd-zen4` e `intel-skylake-avx512` | 2026-10-12 | 2026-10-12 |
| **GPU como opção explícita:** `llama-build.sh --gpu <backend>` + `--gpu-check` + `--cmake-extra`, registro no `AI-CPU-OS-BUILD.txt`, `docs/GPU.md` e Bloco P de validação | 2026-10-12 | 2026-10-12 |
| **Documentação separada por público:** `README.md` reescrito para o **usuário final** e criado o **`README.technical.md`** (manual do mantenedor: contratos, receitas de extensão, o que cada teste prova, CI por dentro, playbook de depuração, glossário) | 2026-10-12 | 2026-10-12 |
| Guardas no CI para a dupla de READMEs (ambos precisam existir e se referenciar) | 2026-10-12 | 2026-10-12 |
| Correção do nome de artefato do `build-llama` (`matrix.profile` → `matrix.family`; o upload falharia) | 2026-10-12 | 2026-10-12 |
| **Fonte do llama.cpp na mídia** (`--iso-source`) + a corrente `LLAMA_SRC` → `AI_LLAMA_SOURCE` → `llama-build.sh --source`: **fecha o air-gapped** (o 1º boot não precisa mais de rede) | 2026-10-12 | 2026-10-12 |
| `build.sh --model-file` / `--llama-source` (o `sudo` limpa o ambiente, então as flags são o caminho manual) | 2026-10-12 | 2026-10-12 |
| `iso.yml`: input `air_gapped`, guarda de tamanho (limite de 2 GiB por arquivo de Release) e dry-run exercitando o payload | 2026-10-12 | 2026-10-12 |
| `docs/ISO.md` § 9 — **checklist de fechamento** da ISO, com o que cada passo prova e onde roda | 2026-10-12 | 2026-10-12 |
| **CI consertado** (o `validate` estava vermelho no `main`): `--iso-repo auto` degrada em vez de abortar + `make iso-dry-run-both` compartilhado entre CI e `make` | 2026-10-12 | 2026-10-12 |
| `build-llama` do CI passou a **compilar do tarball** (`--source`): prova o caminho offline com cmake real, nas 7 famílias | 2026-10-12 | 2026-10-12 |
| `iso.yml` alinhado em `actions/*@v6`/`@v7`, runner fixado em `ubuntu-24.04`, `.gitignore` corrigido e fantasma `profiles/` removido | 2026-10-12 | 2026-10-12 |
| **`upload-artifact` padronizado em `@v7`** nos dois workflows que o usam (era `@v6` no `main` enquanto o PR #3 do Dependabot já trazia o v7) + guarda de CI **negativo e positivo** para não regredir | 2026-10-12 | 2026-10-12 |
| **A ISO Ubuntu não era gerada — corrigido**: o `SHA256SUMS` do Ubuntu marca o modo binário com `*` (o `*` ia para a URL → 404 → `exit code 22` do curl) e lista TODAS as point releases. Padrões ancorados + maior versão + `normalize_iso_name` + falha com mensagem clara | 2026-10-12 | 2026-10-12 |
| **`make iso-select-test`** — `tests/test-iso-selection.sh` + `tests/fixtures/` com `SHA256SUMS` **reais** (Ubuntu 24.04, Debian 13): prova a escolha da ISO sem rede; ligado ao `validate` e ao CI | 2026-10-12 | 2026-10-12 |
| Passo de **diagnóstico em falha** no `iso.yml`: converte os erros do log em **anotações** (públicas, ao contrário dos logs de job); o relatório não derruba mais o job quando o `.sha256` falta | 2026-10-12 | 2026-10-12 |
| **Repo apt local: `apt-get download` abortava o LOTE inteiro** quando um nome não tinha candidato (`gnupg/jq/git` "ausentes" no CI). Corrigido com `packages_with_candidate` + fallback um-a-um + reportar as falhas | 2026-10-12 | 2026-10-12 |
| **`make iso-repo-test`** — `tests/test-iso-repo-filter.sh`: reproduz o bug do lote **offline** (stubs de `apt-get`/`apt-cache`), cobrindo filtro, fallback, degrade e a fixture real do `apt-cache policy` | 2026-10-12 | 2026-10-12 |
| **🔴 SEIS guardas negativos do CI eram decorativos** (`! cmd` não derruba o job com `set -e`): todos convertidos para `if cmd; then exit 1; fi` com anotação `::error::`; meta-guarda proíbe a forma antiga | 2026-10-12 | 2026-10-12 |
| **`make ci-guards-test`** — `tests/test-ci-guards.sh`: planta cada violação numa cópia temporária e **exige** que o job falhe (14 casos, incluindo árvore limpa e a meta-guarda) | 2026-10-12 | 2026-10-12 |
| **Falha intermitente de rede virava "pacote ausente"**: `Acquire::Retries` + **segunda tentativa só dos ausentes** (`repo_missing_packages`), custando segundos em vez de repetir 330 MB | 2026-10-12 | 2026-10-12 |
| **O `verify-iso.sh` tinha viés de distro**: procurava o repo em uso só no `/autoinstall.yaml` e reprovava uma ISO **Debian correta** (run #10). Agora é **distro-aware** (autoinstall × preseed) | 2026-10-12 | 2026-10-12 |
| **`make iso-verify-test`** — `tests/test-verify-iso-repo-distro.sh`: prova os dois caminhos do verificador e **reprova o verificador antigo** (bug provado, não suposto) | 2026-10-12 | 2026-10-12 |
| **Dependências implícitas do runner** (`openssl`, `gzip`, `ca-certificates`) passaram a ser instaladas pelo workflow — descobertas reproduzindo o build num container `ubuntu:24.04` limpo | 2026-10-12 | 2026-10-12 |
| O passo de **diagnóstico** do `iso.yml` passou a capturar `[FAIL]`/`[erro]` do verificador (antes só via `[ERROR]`: entregava o sintoma sem a causa) | 2026-10-12 | 2026-10-12 |
| **`iso/write-pendrive.sh`** — grava a ISO num pendrive com **9 travas** (recusa o disco com `/`, não-removível sem `--allow-internal`, não-disco-inteiro, partição montada; exige `CD001`, espaço e o nome do alvo; **lê de volta** com `cmp -n`) + `make pendrives`/`make pendrive` | 2026-10-14 | 2026-10-14 |
| **`iso/check-iso.sh`** — confere uma ISO **baixada** sem `xorriso` nem root (tamanho, SHA256, `CD001`, Volume ID `AI_CPU_OS_*`, assinatura de boot) + `make iso-check` | 2026-10-14 | 2026-10-14 |
| **O artifact da ISO não é mais gateado pelo limite da Release** — antes o mesmo booleano bloqueava artifact **e** Release, e a ISO air-gapped (~4 GB) era gerada e **descartada**: quem não tem `xorriso` ficava sem caminho para obter o arquivo | 2026-10-14 | 2026-10-14 |
| Correção do `exit 127` que derrubava o run **com a ISO já gerada** (mensagem de aviso com a linha partida virava comando solto) | 2026-10-14 | 2026-10-14 |
| **`llama-build.sh --source <dir|tar.gz>`** — compila de um fonte **local**, sem rede e sem `git`; registra a origem em `AI-CPU-OS-BUILD.txt`. É o primeiro passo da ISO air-gapped | 2026-10-12 | 2026-10-12 |
| **O modelo `.gguf` vai na mídia** (`--iso-model auto|<caminho>|none`) + `late-command` copiando para `/opt/models` + `AI_MODEL_FILE` no `firstboot` + **`--model-file`** no papel `inference` (instala modelo local sem rede) | 2026-10-12 | 2026-10-12 |
| **Repositório apt local na mídia** (`--iso-repo auto|DIR|none`): fecho de dependências, índice gerado com `dpkg-deb`, embutido em `/apt-repo` e usado como fonte EXTRA (Ubuntu: seção `sources` do curtin; Debian: `apt-setup/local0/*`); build recusa release diferente | 2026-10-12 | 2026-10-12 |
| 🎉 **A ISO é GERADA e BOOTADA (Ubuntu)** — primeira vez: build `exit 0`, `verify-iso.sh` **PASS=41/FAIL=0**, `test-vm.sh` **exit 0** (instalou sozinha; 1º boot aplicou com `status=ok`, família `intel-haswell`, llama.cpp compilado do tarball da mídia). **8 bugs reais** corrigidos (`xorriso`, GRUB `--id`, repo no chroot do curtin, marcadores, SIGPIPE, aspas do `-find`) | 2026-10-13 | 2026-10-13 |
| 🧬 **14 famílias de CPU + AVX-512 por padrão** — servidores Xeon Scalable v5–v9/Xeon 6 P (`intel-cascadelake-sp` … `intel-graniterapids-sp`), EPYC Turin e Ryzen 9000 (`amd-zen5`); política AVX-512 `auto` nas famílias que o têm (decisão do dono), com `--no-avx512` e fallback de `-march` sem AVX-512 | 2026-10-16 | 2026-10-16 |
| **`webui/` — interface web local** (`server.py` + `index.html`) para gerar/conferir a ISO **sem decorar flags**: mostra hardware/espaço/ferramentas, monta o `make iso`, roda com log **ao vivo** (SSE), lista `iso/out` e **lista os pendrives** com o comando pronto (nunca pede senha). Só **stdlib**, só **`127.0.0.1`**, lista branca fechada; sem `xorriso` **recusa com o motivo** e aponta o GitHub Actions + `make ui`/`make ui-test` (34 asserções) | 2026-10-15 | 2026-10-15 |
| **Regra 16** no `AGENTS.md` (invariantes da interface web) + **9 guardas novos** no CI, cada um provado por violação plantada (`make ci-guards-test`: 22 → **31** casos) + `webui/` **excluído da ISO** (`--exclude=./webui`) | 2026-10-15 | 2026-10-15 |
| **`--disk auto` consertado** (a mitigação documentada estava **quebrada**: ia literal para o YAML e virava `match: {path: auto}`) + formato do disco validado + **aviso** de disco inexistente + **default do CI = `auto`** (o artefato deixa de sair preso a `/dev/vda`, que só existe em VM) — `make iso-disk-test` (16), `ci-guards` 40 → **43** | 2026-10-16 | 2026-10-16 |
| **`docs/IMPLANTAR-EM-OUTRO-PC.md`** — roteiro para instalar/validar em **outra máquina** (checklist do destino, os 3 modos de falha, o que medir, o que trazer de volta, e o registro honesto do que **não** está provado) | 2026-10-16 | 2026-10-16 |
| `build-iso.sh`: `--keep-templates` (mantém a árvore do autoteste e imprime `TEMPLATES_DIR=…`, o que permite **testar semântica** — não só sintaxe — do `autoinstall.yaml`) + remoção de chamadas `expand_apt_local_block` **duplicadas** | 2026-10-16 | 2026-10-16 |
| 🌐 **Rede do sistema instalado na ISO** (`--network auto\|dhcp\|static\|none` + `--network-ip/gateway/dns/interface`): o **mesmo** netplan vai no `autoinstall.yaml` e em `/preseed/ai-cpu-os-netplan.yaml`, e o `late-command.sh` o instala em `/etc/netplan/99-ai-cpu-os.yaml`, move o netplan do instalador/cloud-init e desliga a rede do cloud-init. No Debian alimenta o `netcfg` da preseed. Corrige o alvo que subia **SEM DHCP** — **provado em VM** (alvo pegou IP sozinho e aceitou SSH). + **3 bugs reais** achados ao executar: arquivos de **0 byte** no 1º boot (unit vazio = `masked`), `--no-mmap` removido do llama.cpp e o `shell-ia.py` devolvendo a linha do protocolo. Guardas: `ci-guards` 43 → **46**, `webui` 38 → **46** | 2026-10-17 | 2026-10-17 |

> ⚠️ **"Concluído" aqui significa "escrito e revisado", NÃO "testado em
> hardware".** Ver a seção de testes reais em `docs/STATE.md`. A validação em
> hardware físico é o principal item de "Em Progresso". A **exceção** é a linha
> acima (ISO), que foi **executada em VM**. A validação em hardware físico é o
> principal item de "Em Progresso".

---

## 🔄 Em Progresso

| Item                                                        | Início     | Nota                                                        |
|-------------------------------------------------------------|------------|-------------------------------------------------------------|
| Validação em hardware real (Xeon E5-2680 v4, família `intel-broadwell`)      | 2026-10-07 | Aguardando acesso ao servidor físico para rodar o smoke-test |
| Validação em hardware real (Ryzen 5 3500X, família `amd-zen2`)              | 2026-10-07 | Aguardando build da imagem + teste do registry/Gitea        |
| Medição de baseline vs. pós-tuning com `llama-bench`        | 2026-10-07 | Depende dos dois itens acima para preencher `docs/STATE.md` |
| Validar a Release `v0.2.0` (binários) e a imagem do GHCR no hardware alvo | 2026-10-07 | Primeiro uso real dos artefatos do CI |
| Executar o protocolo `docs/VALIDATION.md` (blocos A–L) | 2026-10-07 | Roteiro preenchível pronto; **resultados pendentes** |
| ~~🎯 Construir e bootar a ISO de instalação numa VM~~ (Bloco M, Ubuntu) | 2026-10-07 | ✅ **FEITO na sessão #21** (2026-10-13): ISO gerada + `verify-iso` PASS=41 + `test-vm.sh` exit 0 (instalou + 1º boot aplicou). Ver `STATE.md` § 3.3 |
| ~~ISO em base Ubuntu Server~~ (`--distro ubuntu` + autoinstall/Subiquity) | 2026-10-12 | ✅ **Executada contra uma ISO real (sessão #21).** |
| 🔴 **ISO em base Debian** (`--distro debian` + preseed/`apt-setup/local0`) | 2026-10-12 | **Nunca executada** — é o que falta do caminho ISO |
| 🔴 **ISO em HARDWARE FÍSICO** (Xeon e Ryzen) | 2026-10-13 | O caminho funciona em VM; falta no hardware alvo (Blocos A–O) |
| 🟡 **Rede do alvo pós-instalação** (Bloco M.5-b) | 2026-10-17 | ✅ **PROVADO EM VM (sessão #33):** o alvo pegou IP por DHCP sozinho (`DHCPv4 address 10.0.2.15/24 … acquired`), o netplan ficou intacto, o cloud-init desligado e o **SSH funcionou**. Falta o modo `static`, o reboot de persistência e o hardware físico |
| **Flags do llama.cpp mudam entre versões** | 2026-10-17 | Bug real (sessão #33): `--no-mmap` foi removido do upstream e o `ai-server` entrava em loop. A unit usa `${LLAMA_EXTRA_ARGS}` e o `install.sh` detecta a sintaxe no binário |
| **Validar a resolução de famílias em hardware real** (blocos N/O do `VALIDATION.md`) | 2026-10-12 | Testado só com nomes de CPU simulados |
| ✅ ~~ISO air-gapped~~ | 2026-10-12 | **Concluída no código E PROVADA (sessão #21):** o 1º boot compilou do tarball e usou modelo + repo local, sem rede. Resta um resíduo (UI do llama.cpp) — ver `ISO.md` § 6. |

---

## ⏳ Planejado

### Prioridade Alta
- [ ] **🎯 Gerar e bootar o caminho DEBIAN** (`--distro debian`: preseed +
      `apt-setup/local0` + `mtools`/`isolinux`) — o Ubuntu já foi provado (#21).
- [x] **🎯 Gerar a ISO de verdade (Ubuntu)** e rodar o `verify-iso.sh` — ✅ #21.
- [x] **🎯 Bootar a ISO em VM** (`iso/test-vm.sh`) — ✅ #21 (instalou + 1º boot).
- [x] **Validar o caminho `--serial-console`** num boot real — ✅ #21 (marcadores
      no console serial, com o fix do `/dev/console`).
- [ ] **Validar o boot UEFI** (`make iso-vm VM_ARGS="--boot-mode uefi"`) e o
      `md5sum.txt` regenerado (Debian).
- [ ] **Repetir a ISO em hardware físico** (Xeon E5-2680 v4 e Ryzen 5 3500X):
      instalar, ver o 1º boot e medir. Bloco M do `VALIDATION.md`.
- [ ] **Fechar o resíduo air-gapped** (download do UI do llama.cpp no build —
      ver `ISO.md` § 6).
- [ ] **Validar os blocos N e O do `VALIDATION.md`** — famílias em hardware
      real e ciclo `apply`/`revert` das mods.
- [ ] **Atualizar o tutorial ao validar cada família em hardware** — ao fechar
      o marco de validação, revisar `docs/TUTORIAL.md`
      (diretriz obrigatória — Regra 9 do `AGENTS.md`). *(início previsto: a definir)*
- [ ] **Alinhar `docs/{HARDWARE,ARCHITECTURE,TUTORIAL,VALIDATION}.md` ao modelo
      de famílias/papéis** — ainda citam perfis `xeon`/`ryzen` em alguns trechos.
      *(início previsto: a definir)*
- [ ] **Empacotar como imagem/VM de referência** — gerar `qcow2` pré-afinada
      para pular a etapa de build. *(início previsto: a definir)*
- [ ] **Validar persistência de kernel cmdline** — confirmar que
      `intel_idle.max_cstate=1` foi aplicado após reboot (GRUB).
      *(início previsto: a definir)*
- [ ] **Testar fallback de flags** — rodar `llama-build.sh` com
      `AI_ALLOW_UNSUPPORTED_FLAGS=1` para validar o caminho de erro.
      *(início previsto: a definir)*

### Prioridade Média
- [ ] **Medir Zen 3/Zen 4 em hardware real** — ⚠️ **o autor do projeto não tem
      essas máquinas.** O suporte está pronto (corpus no CI + compilação da
      família no `build-llama`); falta a medição. Quem tiver, preencha o Bloco N
      e a coluna "hardware" de `docs/FAMILIES.md` § 9.3.
- [ ] **Validar um backend de GPU** — caminho documentado em
      [`docs/GPU.md`](GPU.md) e Bloco P de `VALIDATION.md`;
      **nenhum backend foi compilado ou testado** por este projeto.
- [ ] **Promover a GPU a um papel (`roles/gpu-*`)** — só depois de existir
      medição real; hoje seria um papel sustentado por zero número.
- [ ] **Suporte a `nvme` tuning** — `mq-deadline` vs `none` scheduler para
      SSD NVMe, e `nr_requests`.
- [ ] **Benchmark automatizado** — script que roda `llama-bench`, salva CSV e
      compara com um baseline versionado.
- [ ] **Suporte a `zram`** como swap comprimido opcional (protegido por flag).

### Prioridade Baixa
- [ ] **Perfil `generic`** — tuning conservador para hardware não listado.
- [ ] **Detecção de RAM SPD** (timings reais) via `dmidecode -t 17`.
- [ ] **Empacotamento `.deb`** dos scripts comuns.

---

## 💡 Ideias Futuras

- **Integração com `systemd-oomd`** para proteger o processo de inferência de
  OOM killer em sistemas com 16 GB.
- **KV cache em disco** com `mmap` + huge pages para aumentar contexto sem
  estourar RAM.
- **Auto-tuner de threads** — testar `-t N` para N em `[núcleos/2 .. threads]`
  e escolher o melhor tokens/s automaticamente.
- **PIN de afinidade de núcleos** com `taskset`/`numactl` para reduzir
  migração de thread.
- **`io_uring` back-end custom** no carregamento de modelo (pesquisa).
- **Suporte a arquiteturas ARM** (ex.: Ampere) — reuso da filosofia, não do
  código.

---

## Histórico de revisões

| Data       | Mudança                                                        |
|------------|----------------------------------------------------------------|
| 2026-10-16 | 🧬 **14 famílias** (Xeon Scalable v5–v9/Xeon 6 P + `amd-zen5`) e **AVX-512 como padrão** nas famílias que o têm (política `auto`, decisão do dono; `--no-avx512` para comparar com AVX2). |
| 2026-10-13 | 🎉 **A ISO é gerada e bootada** (Ubuntu, VM com KVM, sessão #21): moveu "Em Progresso" → "Concluído". O que fica em aberto na ISO: caminho **Debian**, **UEFI** e **hardware físico**; e o resíduo air-gapped do UI do llama.cpp. |
| 2026-10-07 | Criação inicial do roadmap junto com o repositório `0.1.0-alpha`. |
| 2026-10-07 | Adicionado `docs/TUTORIAL.md` + diretriz de tutorial por marco/versão. |
| 2026-10-07 | Adicionada a esteira de CI/CD (validate, build-llama, container), `Makefile` e `docker/`. |
| 2026-10-07 | Publicada a versão **`0.2.0`** (tag `v0.2.0`): marco de CI/CD. Correção do `pkg-config` descoberta pelo 1º run do CI. Ainda **sem validação em hardware**. |
| 2026-10-07 | Correção do RPATH na imagem Docker + criação do protocolo `docs/VALIDATION.md` (blocos A–L) para a validação em hardware. |
| 2026-10-07 | Registrado o **entregável final = ISO de instalação**; criada a implementação `iso/` e o `docs/ISO.md`. Ainda **não construída/bootada**. |
