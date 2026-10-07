# ROADMAP — ai-cpu-os

> Documento vivo. Atualizado a cada mudança de estado.
> **Última atualização:** 2026-10-07

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
| `build.sh` — orquestrador com `--profile`, `--dry-run`, `--yes`       | 2026-10-07 | 2026-10-07 |
| `detect-hardware.sh` — detecção de CPU/RAM/canal/disco                | 2026-10-07 | 2026-10-07 |
| `common/kernel-tuning.sh`, `hugepages.sh`, `governor.sh`              | 2026-10-07 | 2026-10-07 |
| `profiles/xeon/*` (install, llama-build, sysctl, shell-ia, service)   | 2026-10-07 | 2026-10-07 |
| `profiles/ryzen/*` (install, docker, registry, gitea, build-runner)   | 2026-10-07 | 2026-10-07 |
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

> ⚠️ **"Concluído" aqui significa "escrito e revisado", NÃO "testado em
> hardware".** Ver a seção de testes reais em `docs/STATE.md`. A validação em
> hardware físico é o principal item de "Em Progresso".

---

## 🔄 Em Progresso

| Item                                                        | Início     | Nota                                                        |
|-------------------------------------------------------------|------------|-------------------------------------------------------------|
| Validação em hardware real (Xeon E5-2678 v3)                | 2026-10-07 | Aguardando acesso ao servidor físico para rodar o smoke-test |
| Validação em hardware real (Ryzen 5 3500X)                  | 2026-10-07 | Aguardando build da imagem + teste do registry/Gitea        |
| Medição de baseline vs. pós-tuning com `llama-bench`        | 2026-10-07 | Depende dos dois itens acima para preencher `docs/STATE.md` |
| Validar a Release `v0.2.0` (binários) e a imagem do GHCR no hardware alvo | 2026-10-07 | Primeiro uso real dos artefatos do CI |

---

## ⏳ Planejado

### Prioridade Alta
- [ ] **Atualizar o tutorial ao validar cada perfil em hardware** — ao fechar
      o marco de validação do `xeon`/`ryzen`, revisar `docs/TUTORIAL.md`
      (diretriz obrigatória — Regra 9 do `AGENTS.md`). *(início previsto: a definir)*
- [ ] **Empacotar como imagem/VM de referência** — gerar `qcow2` pré-afinada
      para pular a etapa de build. *(início previsto: a definir)*
- [ ] **Validar persistência de kernel cmdline** — confirmar que
      `intel_idle.max_cstate=1` foi aplicado após reboot (GRUB).
      *(início previsto: a definir)*
- [ ] **Testar fallback de flags** — rodar `llama-build.sh` com
      `AI_ALLOW_UNSUPPORTED_FLAGS=1` para validar o caminho de erro.
      *(início previsto: a definir)*

### Prioridade Média
- [ ] **Rebasear o PR #1 do Dependabot** (o `container` falhou por base
      desatualizada, anterior à correção do `pkg-config`).
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
