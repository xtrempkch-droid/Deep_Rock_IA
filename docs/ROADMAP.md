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
| **`llama-build.sh --source <dir|tar.gz>`** — compila de um fonte **local**, sem rede e sem `git`; registra a origem em `AI-CPU-OS-BUILD.txt`. É o primeiro passo da ISO air-gapped | 2026-10-12 | 2026-10-12 |
| **O modelo `.gguf` vai na mídia** (`--iso-model auto|<caminho>|none`) + `late-command` copiando para `/opt/models` + `AI_MODEL_FILE` no `firstboot` + **`--model-file`** no papel `inference` (instala modelo local sem rede) | 2026-10-12 | 2026-10-12 |
| **Repositório apt local na mídia** (`--iso-repo auto|DIR|none`): fecho de dependências, índice gerado com `dpkg-deb`, embutido em `/apt-repo` e usado como fonte EXTRA (Ubuntu: seção `sources` do curtin; Debian: `apt-setup/local0/*`); build recusa release diferente | 2026-10-12 | 2026-10-12 |

> ⚠️ **"Concluído" aqui significa "escrito e revisado", NÃO "testado em
> hardware".** Ver a seção de testes reais em `docs/STATE.md`. A validação em
> hardware físico é o principal item de "Em Progresso".

---

## 🔄 Em Progresso

| Item                                                        | Início     | Nota                                                        |
|-------------------------------------------------------------|------------|-------------------------------------------------------------|
| Validação em hardware real (Xeon E5-2680 v4, família `intel-broadwell`)      | 2026-10-07 | Aguardando acesso ao servidor físico para rodar o smoke-test |
| Validação em hardware real (Ryzen 5 3500X, família `amd-zen2`)              | 2026-10-07 | Aguardando build da imagem + teste do registry/Gitea        |
| Medição de baseline vs. pós-tuning com `llama-bench`        | 2026-10-07 | Depende dos dois itens acima para preencher `docs/STATE.md` |
| Validar a Release `v0.2.0` (binários) e a imagem do GHCR no hardware alvo | 2026-10-07 | Primeiro uso real dos artefatos do CI |
| Executar o protocolo `docs/VALIDATION.md` (blocos A–L) | 2026-10-07 | Roteiro preenchível pronto; **resultados pendentes** |
| **🎯 Construir e bootar a ISO de instalação numa VM** (Bloco M) | 2026-10-07 | Entregável final; maior risco não validado do projeto |
| **ISO em base Ubuntu Server** (`--distro ubuntu` + autoinstall/Subiquity) | 2026-10-12 | Implementada e validada no autoteste de templates; **nunca executada** contra uma ISO real |
| **Validar a resolução de famílias em hardware real** (blocos N/O do `VALIDATION.md`) | 2026-10-12 | Testado só com nomes de CPU simulados |
| ~~ISO air-gapped~~ | 2026-10-12 | ✅ **Concluída no código** (sessão #17): fonte, modelo e repositório na mídia. O 1º boot não precisa de rede. **Nada mais a implementar** — o que falta é executar (boot em VM). |

---

## ⏳ Planejado

### Prioridade Alta
- [ ] **🎯 Gerar as duas ISOs de verdade** (Ubuntu e Debian) numa máquina com
      `xorriso` + rede, e rodar `make iso-verify` (o build já verifica sozinho).
      É o passo que falta para sair de "escrito" para "existe".
- [ ] **🎯 Bootar a ISO em VM** (`make iso-vm`) — é o critério de conclusão e o
      maior risco não validado. O `iso/test-vm.sh` já automatiza a espera e o
      julgamento; falta executá-lo.
- [ ] **Validar o caminho `--serial-console`** num boot real (é o que permite ao
      `test-vm.sh` enxergar o primeiro boot).
- [ ] **Validar o boot UEFI** (`make iso-vm VM_ARGS="--boot-mode uefi"`) e o
      `md5sum.txt` regenerado (Debian).
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
- [ ] **Variante air-gapped da ISO** — embutir o fonte do llama.cpp e os `.deb`
      necessários para instalar **sem internet**.
- [ ] **Variante com binário pré-compilado** — usar os `.tar.gz` da Release em
      vez de compilar no primeiro boot (instalação muito mais rápida).
- [ ] **Suporte a Ubuntu na ISO** (autoinstall/Subiquity) via `--distro ubuntu`.
- [ ] **Mesclar o PR #1 do Dependabot** — rebaseado sobre `main` com a
      correção do RPATH e **✅ verde**; só falta clicar em *Merge*.
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
| 2026-10-07 | Criação inicial do roadmap junto com o repositório `0.1.0-alpha`. |
| 2026-10-07 | Adicionado `docs/TUTORIAL.md` + diretriz de tutorial por marco/versão. |
| 2026-10-07 | Adicionada a esteira de CI/CD (validate, build-llama, container), `Makefile` e `docker/`. |
| 2026-10-07 | Publicada a versão **`0.2.0`** (tag `v0.2.0`): marco de CI/CD. Correção do `pkg-config` descoberta pelo 1º run do CI. Ainda **sem validação em hardware**. |
| 2026-10-07 | Correção do RPATH na imagem Docker + criação do protocolo `docs/VALIDATION.md` (blocos A–L) para a validação em hardware. |
| 2026-10-07 | Registrado o **entregável final = ISO de instalação**; criada a implementação `iso/` e o `docs/ISO.md`. Ainda **não construída/bootada**. |
