# JOURNAL — Diário de trabalho e continuidade

> **Para que serve:** garantir que **qualquer sessão futura (ou você, depois de
> esquecer) retome o projeto sem perder nada.** Enquanto o `docs/STATE.md` diz
> *onde estamos*, este diário diz *como chegamos aqui*, *o que ficou em aberto*
> e *quais armadilhas já foram pisadas*.
>
> **Quando ler:** logo depois do [`AGENTS.md`](../AGENTS.md) e do
> [`docs/STATE.md`](STATE.md).
> **Quando escrever:** **ao fim de TODA sessão de trabalho** (ver § 8).
>
> **Última entrada:** sessão **#7** (2026-10-07) — ISO de instalação.

---

## 1. ⏱️ Retomada em 5 minutos

Se você só tem 5 minutos, faça exatamente isto:

```bash
# 1. Ler o essencial (nesta ordem)
less AGENTS.md            # propósito + regras
less docs/STATE.md        # onde estamos + "Próxima ação imediata" (§ 6)
less docs/JOURNAL.md      # este arquivo: § 5 (threads abertas) e § 6 (armadilhas)

# 2. Sincronizar e conferir a saúde do repositório
cd /home/juju/Deep_Rock_IA
git pull --ff-only        # ou: git fetch && git status
make ci                   # lint + docs + dry-run (igual ao CI 'validate')
git log --oneline -12     # os últimos passos dados

# 3. Ver o que o CI já provou (verde) e o que NÃO foi provado
#    - validate      ✅ verde
#    - build-llama   ✅ verde (compila e roda de verdade)
#    - container     ✅ verde (imagem no GHCR)
#    - iso           ⚠️ NUNCA executado
```

**Depois disso**, vá para a "Próxima ação imediata" em `docs/STATE.md` § 6.

> ⚠️ **Regra de ouro da retomada:** não confie na memória — confie no
> `STATE.md` § 6. Ele é reescrito ao fim de cada sessão justamente para isto.

---

## 2. 🧰 Inventário do ambiente de desenvolvimento

Isto evita perder tempo (re)descobrindo o que já se sabe sobre **esta** máquina.

| Item | Situação | Consequência |
|------|----------|--------------|
| Máquina | Notebook AMD A4-3300M, 2 núcleos, Ubuntu 25.10 | **Compilar o llama.cpp localmente é inviável** (~40 min+, testado até 32 min sem terminar). Use o CI. |
| `shellcheck` | ✅ em `~/.local/bin` (instalado via `pip install --user shellcheck-py`) | `make shellcheck` funciona |
| `yamllint` | ✅ (instalado via `pip install --user yamllint`) | `make yaml` funciona |
| `jq`, `make`, `git`, `docker` | ✅ | ok |
| `xorriso`, `mtools` | ❌ **ausentes** | **Não é possível gerar a ISO aqui.** Use `make iso-dry-run` (só simula). |
| `gh` (GitHub CLI) | ❌ ausente e sem token | Não dá para disparar/consultar workflows por CLI. Use o **navegador** ou a **API pública**. |
| API do GitHub (sem token) | 60 req/h | **Nunca faça polling agressivo** — ativa a "abuse detection" e bloqueia por minutos. Ver § 6. |

### Como o CI é verificado daqui (sem `gh`)

- **Navegador** (preferido): abrir `https://github.com/xtrempkch-droid/Deep_Rock_IA/actions`
  e ler os rótulos (`completed successfully` / `failed`).
- **API pública** (com moderação):
  ```bash
  curl -s -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/xtrempkch-droid/Deep_Rock_IA/actions/runs?per_page=5" \
    | jq -r '.workflow_runs[] | "\(.name) \(.status)/\(.conclusion // "…")"'
  ```
- **Mensagem de erro de um job** (os logs exigem login, mas as *annotations* não):
  ```bash
  curl -s -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/xtrempkch-droid/Deep_Rock_IA/check-runs/<id>/annotations" \
    | jq -r '.[].message'
  ```

---

## 3. 📖 Contexto mínimo do projeto (se você esqueceu tudo)

| Pergunta | Resposta curta | Onde aprofundar |
|----------|----------------|-----------------|
| O que é isto? | Um SO Debian afinado para **LLM 100% em CPU** | `README.md` |
| Qual é o **fim** do projeto? | 🎯 Uma **ISO de instalação** com tudo embutido | `docs/ISO.md` |
| Por que CPU, se é lento? | Os dois hardwares alvo **não têm GPU utilizável** | `docs/HARDWARE.md` |
| Qual é o gargalo real? | **Banda de memória**, não FLOPs | `docs/TUNING.md` § 0 |
| Quem são os alvos? | Xeon E5-2678 v3 (inferência) e Ryzen 5 3500X (build) | `docs/HARDWARE.md` |
| O que **nunca** fazer? | AVX-512, usar a RX 580 p/ compute, `GGML_NATIVE=ON` no Docker | `AGENTS.md` Regras 12 |

### Regras que mais quebram o CI (e a paciência)

1. Todo `.sh` em **modo estrito** — bash: `set -euo pipefail`; POSIX sh: `set -eu`.
2. `docs/TUTORIAL.md` **obrigatório** a cada marco/versão.
3. Nunca remover código sem registrar o motivo em `docs/ARCHITECTURE.md`.
4. Nunca habilitar AVX-512 em lugar nenhum.

---

## 4. 🗓️ Diário de sessões (ordem cronológica)

> Cada sessão registra: **objetivo → o que foi feito → decisões → problemas →
> commits**. Este é o "filme"; o `STATE.md` é a "foto" atual.

### Sessão #1 — 2026-10-07 · Criação do projeto

- **Objetivo:** criar o repositório `ai-cpu-os` completo a partir da
  especificação (SO para LLM em CPU, dois perfis).
- **Feito:** 24 arquivos — `README`, `AGENTS`, `LICENSE`, `build.sh`,
  `detect-hardware.sh`, `common/` (3), `profiles/xeon/` (5),
  `profiles/ryzen/` (5), `tests/smoke-test.sh` e 6 docs.
- **Decisões:** Bash puro (sem Ansible) para zero dependências no alvo;
  perfis separados por hardware (não "config média"); `--dry-run` em tudo.
- **Verificado:** `bash -n` em 12 scripts, `py_compile`, YAML, `--dry-run`.
- **Commits:** `6a4d4aa` (inicial), `6a8cbd5`.

### Sessão #2 — 2026-10-07 · Tutorial + diretriz

- **Objetivo:** atender o pedido de um **tutorial explicado** obrigatório.
- **Feito:** `docs/TUTORIAL.md` (13 seções, didático) + **Regras 9 e 10** no
  `AGENTS.md` (tutorial obrigatório por marco/versão).
- **Decisões:** a tag `v0.1.0-alpha` foi **movida** para incluir o tutorial —
  a própria regra diz que nenhuma versão é válida sem ele.
- **Commits:** `1015dbe` (+ `510ff57`, feito por você pelo site: "quad-channel").

### Sessão #3 — 2026-10-07 · CI/CD (o GitHub compila o sistema)

- **Objetivo:** fazer o GitHub **compilar e validar** o sistema.
- **Feito:** `validate.yml`, `build-llama.yml`, `container.yml`,
  `docker/Dockerfile`, `Makefile`, templates de issue/PR, Dependabot,
  `docs/CI.md`, badges.
- **Decisões:** `build-llama` só em manual/tag/semanal (build é caro);
  `container` publica **duas** variantes (`portable` e `znver2`);
  `GGML_NATIVE=OFF` **obrigatório** no Docker.
- **Problemas:** shellcheck (`SC2046`/`SC2034`/`SC2155`) — todos corrigidos.
- **Commits:** `6da0c35`.

### Sessão #4 — 2026-10-07 · 🐛 Bug 1: `pkg-config`

- **Objetivo:** investigar uma falha do CI.
- **Achado:** o backend BLAS do ggml usa `find_package(PkgConfig)` e o
  `libopenblas-dev` **não** traz o `pkg-config` → o CMake aborta.
  **Este bug também quebraria o build nativo** (`llama-build.sh`/`install.sh`).
- **Corrigido em 4 lugares:** Dockerfile, `llama-build.sh`, `install.sh`,
  workflow. Documentado em `docs/CI.md` § 8.1 e `TROUBLESHOOTING.md`.
- **Lição:** *lint verde ≠ build comprovado.*
- **Commits:** `4cde4bb`, `af4f599`.

### Sessão #5 — 2026-10-07 · 🐛 Bug 2: `exit 127` (RPATH) + v0.2.0

- **Objetivo:** entender por que o container falhava.
- **Achado:** o llama.cpp compila **bibliotecas compartilhadas** e os binários
  carregam **RPATH absoluto `/src/build/bin`**. O `COPY build/bin` movia os
  binários sem corrigir o RPATH → o loader não achava `libllama.so` → **127**.
  Só apareceu no **PR** porque o passo de smoke só roda em `pull_request`.
- **Corrigido:** `cmake --install` + `-DCMAKE_INSTALL_RPATH=/usr/local/lib` +
  `ldconfig` + **auto-verificação dentro do Dockerfile**.
- **Commits:** `b5d86bc`, `566583c`, `8d12dab`.
- **Versão:** tag **`v0.2.0`** publicada (marco de CI/CD) + Release com os
  `.tar.gz` dos dois perfis. ⚠️ **Sem validação de hardware nesta versão.**

### Sessão #6 — 2026-10-07 · Protocolo de validação

- **Objetivo:** documentar **todos** os testes para você executar e trazer os
  resultados depois.
- **Feito:** `docs/VALIDATION.md` — blocos 0 + A–L, com comandos exatos, campos
  `_(preencher)_`, critérios de sucesso e um **template de relatório**.
- **Commits:** `a9632bb`.

### Sessão #7 — 2026-10-07 · 🎯 A ISO (entregável final)

- **Objetivo:** registrar e implementar que **o projeto termina com uma ISO de
  instalação** já com tudo embutido.
- **Feito:** meta oficial no `AGENTS.md` § 1 + **Regra 13**; `iso/build-iso.sh`
  (remaster da Debian netinst), `iso/preseed/*` (preseed + `late-command` +
  serviço de 1º boot), `docs/ISO.md`, workflow `iso.yml`, **Bloco M** no
  protocolo de validação.
- **Decisão central:** aplicar no **primeiro boot**, não no `late_command` —
  o systemd do alvo não roda na instalação, o kernel é outro, o hardware só é
  visto por completo depois, e assim a **mesma ISO** serve para Xeon e Ryzen
  (perfil `auto`).
- **Problema corrigido de passagem:** o guarda do CI exigia
  `set -euo pipefail` em **todo** `.sh`, mas o `late-command.sh` roda no
  **dash** do instalador (sem `pipefail`) → refinado para aceitar `set -eu`.
- **Commits:** `4a45583`.
- **⚠️ Não validado:** a ISO **nunca foi construída nem bootada** (sem
  `xorriso` nesta máquina).

### Sessão #8 — 2026-10-07 · Documentação de continuidade

- **Objetivo:** garantir que tudo esteja documentado para retomar sem perder nada.
- **Feito:** este `docs/JOURNAL.md` + seção "Retomada rápida" no `AGENTS.md` +
  **Regra 14** (registrar o fim de cada sessão) + guardas de CI para os dois.
- **Bônus (inconsistência corrigida):** o Xeon estava descrito como "dual
  channel" em `AGENTS.md`/`HARDWARE.md` mas como "quad" no `README.md`.
  Unificado em **quad channel** e `detect-hardware.sh` passou a **contar os
  canais reais** (`Bank Locator`) em vez de reportar sempre "dual".
- **Problemas:** uma edição por bloco (sem incluir a linha seguinte) **juntou
  duas linhas** da árvore do `AGENTS.md` — detectado na revisão e corrigido.
  Virou armadilha registrada em § 6.
- **Verificado:** `make validate` (lint, shellcheck, yamllint, iso-lint, docs),
  `detect-hardware.sh` re-executado, guardas simulados. **Não verificado:**
  a contagem `quad` real (precisa de `dmidecode` no Xeon — Bloco B).
- **Commits:** `git log -1 --format=%h` → *o commit desta sessão* (registrado logo abaixo).

---

## 5. 🧵 Threads abertas (o que ficou no ar)

> **Esta é a seção mais importante para retomar.** Lista o que está *incompleto*,
> *decidido mas não feito* ou *em dúvida*.

### 5.1 Bloqueado por ambiente (não dá para fazer nesta máquina)

| Thread | Bloqueio |
|--------|----------|
| Gerar e bootar a ISO | Falta `xorriso`/`mtools`. *Solução:* `sudo apt install -y xorriso isolinux mtools`, ou rodar o workflow `iso` no GitHub. |
| Validar em hardware real | Falta acesso físico ao Xeon e ao Ryzen. |
| Medir tokens/s (`llama-bench`) | Depende do item acima. |
| Compilar o llama.cpp localmente | CPU fraca (2 núcleos) — use os binários da Release `v0.2.0` ou o CI. |

### 5.2 Decidido, mas ainda não executado

| Thread | Nota |
|--------|------|
| **PR #1 do Dependabot** | ✅ verde, rebaseado sobre `main`, **não mesclado**. Basta clicar em *Merge*. Bumps verificados com `git ls-remote`. |
| **Bloco M** (`VALIDATION.md`) | Roteiro da ISO pronto; nenhuma execução ainda. |
| **Blocos A–L** (`VALIDATION.md`) | Idem — nenhum resultado preenchido. |
| **`md5sum.txt` da ISO** | Gerado pelo script, mas **nunca validado** por um instalador real. |
| **Boot UEFI da ISO** | Implementado como *best-effort* (precisa de `mtools`); **não testado**. |

### 5.3 Dúvidas em aberto (requerem decisão sua)

| Dúvida | Contexto |
|--------|----------|
| A ISO deve ser **air-gapped** (sem internet)? | Hoje o 1º boot precisa de rede para clonar o llama.cpp. Um variante pode embutir o fonte + `.deb`. Ver `docs/ISO.md` § 8. |
| Embutir o **binário pré-compilado** em vez de compilar no 1º boot? | Muito mais rápido, mas exige uma ISO **por perfil**. |
| Suportar **Ubuntu** também? | O usuário pediu "Ubuntu ou Debian". Hoje só Debian. Ubuntu = autoinstall/Subiquity (mecanismo diferente). |

> ✅ **Resolvido na sessão #8:** a dúvida "o Xeon é dual ou quad channel?" foi
> encerrada — é **quad channel** (Haswell-EP tem 4 canais; 4 slots × 4 GB).
> `README.md`, `AGENTS.md` e `docs/HARDWARE.md` foram unificados e
> `detect-hardware.sh` passou a contar os canais reais via `Bank Locator`
> (antes ele reportava sempre "dual"). Confirmar no Bloco B.

### 5.4 Deliberadamente adiado

- Perfil `generic` (hardware não listado).
- Tuning de NVMe (`mq-deadline` vs `none`).
- Benchmark automatizado com CSV + baseline versionado.
- Assinatura GPG da ISO.
- Imagem de VM (`qcow2`) via Packer.

---

## 6. 🕳️ Armadilhas já pisadas (não repita)

| Armadilha | O que acontece | Como evitar |
|-----------|----------------|-------------|
| `grep` **sem arquivo** no terminal | Ele lê o **stdin** e **trava a sessão** | Sempre passe arquivo/glob, ou use `grep ... <<<"$var"` |
| Polling agressivo na **API do GitHub** sem token | `abuse detection` — bloqueia por vários minutos | Poll no **navegador**; na API, com calma (60 req/h) |
| Assumir que **logs** do CI são públicos | HTTP **403** (exige login) | Use as *annotations* (públicas) ou o navegador logado |
| `cmake` no **Docker** com `GGML_NATIVE=ON` | O CMake pega a CPU do **runner** (pode ter AVX-512) → `SIGILL` no alvo | Mantenha `GGML_NATIVE=OFF` no container (Regra 12) |
| Copiar `build/bin` para outra pasta | **RPATH absoluto** → `error while loading shared libraries` → **exit 127** | Use `cmake --install` + `CMAKE_INSTALL_RPATH` + `ldconfig` |
| Build **nativo** sem `pkg-config` | `Could NOT find PkgConfig` no CMake | Já instalado pelos scripts; se faltar, `apt install pkg-config` |
| Passos de CI **condicionais** (ex.: só em PR) | Ficam **sem cobertura** até alguém exercitá-los | Só apareceu no PR do Dependabot — teste os dois caminhos |
| Tokens `@@...@@` em **comentário** de template | O guarda "sobrou marcador" dava **falso positivo** e abortava o build | O guarda checa apenas os **nomes** de marcador reais |
| `git push` rejeitado (`non-fast-forward`) | Alguém (você, pelo site) comitou no remoto | `git fetch` → inspecionar → `git rebase origin/main` → push (nunca force no `main`) |
| `sed -i "s/.*texto.*/.../"` em `.md` | Pode quebrar linha sem intenção | Prefira edições por bloco com contexto |
| Editar **bloco** de texto incluindo a quebra de linha final | O texto seguinte **gruda** na mesma linha (ex.: `perfil├── .github/`) e corrompe a árvore/lista | **Sempre confira o resultado** (`sed -n ...p`, `git diff`) e inclua a linha seguinte no contexto da edição |
| `sed -i` na 1ª linha de um script com `#!` | Pode trocar o **shebang** (`#!/usr/bin/env bash` vs `#!/bin/sh`) e mudar o interpretador | Nunca use `sed -i '1s/…'`; confirme o shebang depois (o CI verifica o modo estrito por shebang) |

---

## 7. 🧭 Convenções de trabalho (o que o CI exige)

O job **`project-rules`** do CI transforma as regras do `AGENTS.md` em testes.
Se você violar uma, o **CI fica vermelho**:

| Regra verificada | Consequência |
|------------------|--------------|
| Arquivos obrigatórios presentes (inclui `iso/`, `docs/ISO.md`, `JOURNAL.md`) | Erro nomeando o arquivo que falta |
| `AGENTS.md` referencia `docs/TUTORIAL.md` e diz "entregável final" | Erro |
| Modo estrito em todo `.sh` (bash: `set -euo pipefail`; sh: `set -eu`) | Erro nomeando o script |
| `docs/STATE.md` tem "Próxima ação imediata", "Última atualização", "Métricas de performance" | Erro |
| `docs/VALIDATION.md` segue preenchível (`_(preencher)_`, `Bloco F`, `Template de relatório`) | Erro |
| Templates do preseed mantêm os marcadores (`@@PROFILE@@`, `late_command`, `firstboot-pending`) | Erro |

### Como rodar **tudo** localmente antes de commitar

```bash
export PATH="$HOME/.local/bin:$PATH"   # shellcheck + yamllint
make ci          # = lint (bash/shellcheck/python/yaml/iso) + docs + dry-run
```

---

## 8. ✍️ Como registrar uma nova sessão (template)

Ao **fim de cada sessão**, faça nesta ordem:

1. **Acrescente uma sessão** em § 4 (copie este template):

```markdown
### Sessão #N — AAAA-MM-DD · <título curto>

- **Objetivo:** <o que você queria resolver>
- **Feito:** <arquivos/mudanças concretas>
- **Decisões:** <escolhas e o porquê (o mais valioso p/ o futuro)>
- **Problemas:** <o que deu errado e como resolveu>
- **Verificado:** <comandos/testes — e o que NÃO foi verificado>
- **Commits:** `<hash>` — <título>
```

2. **Atualize § 5** (threads abertas): feche o que resolveu, acrescente o novo.
3. **Atualize § 2** se mudou o ambiente (instalou/removeu ferramenta).
4. **Atualize § 6** com armadilhas novas.
5. **Atualize o `docs/STATE.md`** — § 3 (status), § 5 (métricas) e **§ 6
   (Próxima ação imediata)**.
6. Atualize `docs/ROADMAP.md` se moveu algo entre seções.
7. Se fechou **marco/versão**: atualize `docs/TUTORIAL.md` (**Regra 9**).
8. Rode `make ci` e só então commite/push.

> **Se você só puder fazer uma coisa:** atualize a **"Próxima ação imediata"**
> do `STATE.md` e as **threads abertas** (§ 5) daqui. É o que mais salva uma
> sessão futura.

---

## 9. Histórico deste documento

| Data | Mudança |
|------|---------|
| 2026-10-07 | Criação — diário de continuidade (sessões #1–#8), inventário do ambiente, threads abertas e armadilhas. |

> **Ao criar uma sessão nova, atualize também a "Última entrada" no topo deste
> arquivo** — é o primeiro número que uma sessão futura olha para saber se está
> lendo algo atualizado.
