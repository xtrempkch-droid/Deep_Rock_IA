# ARCHITECTURE — ai-cpu-os

> **Última atualização:** 2026-10-07

Este documento descreve **como o sistema é montado**, **por onde os dados
fluem** e **por que decidimos assim** — incluindo alternativas descartadas.

---

## 1. Visão geral — os sistemas e como se conectam

```text
                      ┌───────────────────────────────────────────────┐
                      │                DESENVOLVEDOR                   │
                      │        (git push, docker build, curl)          │
                      └───────────────┬───────────────┬───────────────┘
                                      │               │
                    git push (SSH 2222)               │ docker push
                                      │               │ localhost:5000
                                      ▼               ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │                    SISTEMA B — PERFIL "ryzen"                    │
        │                AMD Ryzen 5 3500X · 64 GB DDR4 (SC ⚠️)            │
        │                                                                  │
        │   ┌──────────────┐   ┌───────────────────┐   ┌───────────────┐   │
        │   │    Gitea     │   │  Docker Engine    │   │   Registry    │   │
        │   │  :3000 web   │   │  + Compose        │──▶│  :5000 local  │   │
        │   │  :2222 ssh   │   │                   │   │  (registry:2) │   │
        │   └──────┬───────┘   └─────────┬─────────┘   └───────┬───────┘   │
        │          │                     │                     │           │
        │          └──────────┬──────────┴─────────────────────┘           │
        │                     ▼                                            │
        │            build-runner.sh  (build + push com cache)             │
        │                                                                  │
        │   RX 580 → apenas saída de vídeo (NÃO computa)                   │
        └───────────────────────────────┬─────────────────────────────────┘
                                        │
                     imagem Docker (docker save | scp | docker load)
                     ou pull direto do registry (se exposto na LAN)
                                        │
                                        ▼
        ┌─────────────────────────────────────────────────────────────────┐
        │                    SISTEMA A — PERFIL "xeon"                     │
        │          Intel Xeon E5-2678 v3 · 12c/24t · 16 GB DDR3 DC         │
        │                                                                  │
        │   ┌────────────────────────┐        ┌────────────────────────┐  │
        │   │   llama-server         │◀───────│   shell-ia.py          │  │
        │   │   (systemd service)    │  HTTP  │   (sandbox, tools)     │  │
        │   │   .gguf em huge pages  │  :8080 │   subprocess + whitelist│  │
        │   └───────────┬────────────┘        └───────────┬────────────┘  │
        │               │                                 │               │
        │               └──────────────┬──────────────────┘               │
        │                              ▼                                  │
        │                   kernel tuning (common/)                       │
        │     governor · huge pages · sysctl · C-states · io_uring        │
        └─────────────────────────────────────────────────────────────────┘
```

---

## 2. Componentes

### 2.1 `build.sh` (orquestrador raiz)
- Interpreta `--profile auto|xeon|ryzen`, `--dry-run`, `--yes`.
- Chama `detect-hardware.sh` (se `auto`) para decidir o perfil.
- Chama `common/*` (tuning de kernel, huge pages, governor).
- Delega ao `profiles/<perfil>/install.sh`.
- **Não** executa lógica de perfil diretamente — apenas orquestra.

### 2.2 `detect-hardware.sh`
- Lê `/proc/cpuinfo` e `lscpu` para modelo, núcleos, threads e flags ISA.
- Usa `dmidecode -t 17` (fallback `lshw`) para inferir canais de memória.
- Usa `lsblk`/`nvme list` para diferenciar NVMe de SATA.
- Emite um relatório legível e uma linha `PROFILE=...` consumível por script.
- **Nunca** aplica nada — é somente leitura.

### 2.3 `common/` (tuning compartilhado)
- `kernel-tuning.sh` — escreve `/etc/sysctl.d/99-ai-tuning.conf`, verifica
  `io_uring` e orienta o kernel cmdline.
- `hugepages.sh` — configura THP e, opcionalmente, huge pages estáticas.
- `governor.sh` — aplica governor `performance` e C-states rasos.

### 2.4 `profiles/xeon/`
- `llama-build.sh` — clona e compila o llama.cpp com flags AVX2/FMA/F16C +
  OpenBLAS, **validando as flags antes**.
- `shell-ia.py` — shell em linguagem natural com ferramentas e sandbox.
- `ai-server.service` — unit systemd para o `llama-server`.
- `sysctl.conf` — tuning específico do perfil.

### 2.5 `profiles/ryzen/`
- `docker-setup.sh` — instala Docker Engine + Compose (repo oficial).
- `registry-setup.sh` — sobe `registry:2` em `localhost:5000`.
- `gitea-compose.yml` — Gitea (SQLite, :3000, SSH :2222).
- `build-runner.sh` — build Docker com cache + push ao registry local.

### 2.6 `docs/TUTORIAL.md` (documento de encerramento de marco/versão)
- Não é um componente de código: é a **porta de entrada didática**.
- Cobre o fluxo completo (preparar → detectar → simular → aplicar → usar →
  medir) para os **dois** perfis, explicando o "o quê" e o "por quê".
- **Obrigatório** criar/atualizar em cada marco/versão (Regras 9 e 10 do
  `AGENTS.md`). Seu estado é refletido em `docs/STATE.md`.

---

## 3. Fluxo de dados — um comando vira ação

### Fluxo A: usuário pergunta algo ao shell-IA (Xeon)

```text
Usuário digita pergunta em linguagem natural
        │
        ▼
shell-ia.py  ──monta prompt──▶  llama-server (HTTP :8080)
        │                              │
        │◀──── resposta (tool call?) ──┘
        │
        ├─ se tool call:
        │     valida contra WHITELIST
        │     executa (subprocess, sem shell=True, timeout)
        │     realimenta o modelo com o resultado
        ▼
Resposta final ao usuário
```

### Fluxo B: build + push de imagem (Ryzen)

```text
build-runner.sh <repo> <tag>
        │
        ├─ valida Dockerfile no repositório
        ├─ docker build --cache-from (registry local)
        ├─ docker tag localhost:5000/<repo>:<tag>
        └─ docker push localhost:5000/<repo>:<tag>
                │
                ▼
        registry privado (:5000)
```

### Fluxo C: aplicação do tuning (ambos)

```text
sudo ./build.sh --profile auto
        │
        ▼
detect-hardware.sh  ──▶  escolhe perfil
        │
        ▼
common/kernel-tuning.sh  →  /etc/sysctl.d/99-ai-tuning.conf + reload
common/hugepages.sh      →  THP always / huge pages estáticas
common/governor.sh       →  governor performance + C-states
        │
        ▼
profiles/<perfil>/install.sh
        │
        ▼
tests/smoke-test.sh  (validação rápida)
```

---

## 4. Decisões de design (e por quê)

| Decisão                                                    | Motivo                                                                                                     |
|------------------------------------------------------------|------------------------------------------------------------------------------------------------------------|
| **Scripts Bash em vez de Ansible**                         | Zero dependências no alvo (Ansible exigiria Python + SSH). O alvo é um Debian mínimo, recém-instalado.      |
| **Perfis separados `xeon`/`ryzen`**                        | Hardware muito distinto (banda, canais, ISA). Evita "configuração média" que não otimiza nenhum dos dois.  |
| **`--dry-run` em tudo**                                    | Tuning de kernel é sensível; prever o que será feito reduz risco.                                          |
| **Verificação de ISA em tempo de execução**                | Nunca assumir AVX-512; `-march` errado = `SIGILL` (crash).                                              |
| **`DGGML_NATIVE=ON` como padrão**                          | Deixa o compilador usar a ISA real; combinado com checagem de flags, é seguro.                             |
| **OpenBLAS em vez de MKL**                                 | MKL é proprietária e otimizada para Intel; OpenBLAS é livre, portátil e ótima em AVX2.                     |
| **`registry:2` local em `localhost:5000`**                 | Simples, sem TLS obrigatório em `localhost`, sem custo de nuvem.                                           |
| **Gitea com SQLite**                                       | Não há necessidade de Postgres para um servidor de projetos pessoal; SQLite = menos partes móveis.         |
| **shell-IA com whitelist de comandos**                     | LLM pode alucinar comandos; whitelist + sem `shell=True` + timeout = sandbox mínimo viável.                |
| **`kernel.numa_balancing=0` só em single-socket**          | Em single-socket, o balanceamento NUMA adiciona overhead sem benefício.                                    |
| **Huge pages como `always` (com fallback `madvise`)**      | `always` é mais simples e benéfico para cargas de longa duração; `madvise` é mais conservador.             |

---

## 5. Alternativas consideradas e descartadas

| Alternativa                                          | Por que foi descartada                                                                                  |
|------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| Usar **a RX 580 para inferência** (OpenCL/Vulkan)    | Apresenta artefatos de tela sob carga → instabilidade; 8 GB é pouco para LLMs grandes.                  |
| **Gentoo / compilação total do SO**                  | Ganho marginal sobre um Debian bem afinado; tempo de manutenção desproporcional.                         |
| **Kubernetes em vez de Docker Compose**              | Overhead absurdo para 2-3 containers; complexidade operacional sem retorno.                              |
| **`-march=native` cru (sem checagem)**               | Perigoso: se o binário for copiado entre as duas máquinas, gera `SIGILL`.                                   |
| **Ansible / Nix**                                    | Dependência extra no alvo; o objetivo é "Debian cru → pronto em um comando".                             |
| **Postgres para o Gitea**                            | Não há carga que justifique; SQLite reduz partes móveis.                                                 |
| **AVX-512 por emulação (`SDE`)**                     | Emulação é mais lenta que AVX2 nativo — contra a filosofia de ganho real.                                |
| **Swap em disco para modelos grandes no Xeon**       | Thrashing de I/O destrói latência; melhor reduzir o tamanho do modelo.                                   |

---

## 6. Princípios de engenharia

1. **Idempotência:** rodar `build.sh` duas vezes não corrompe o sistema.
2. **Falha ruidosa e clara:** `set -euo pipefail` + mensagens `ERROR` com
   contexto.
3. **Nada destrutivo sem confirmação:** exceto com `--yes`.
4. **Documentar o "porquê", não só o "como":** cada otimização tem uma
   justificativa em `docs/TUNING.md`.
5. **Medir, não adivinhar:** toda mudança de performance registra número em
   `docs/STATE.md`.
6. **Ensinar, não só entregar:** ao fechar cada marco/versão, o tutorial
   explicado (`docs/TUTORIAL.md`) é atualizado — ele é a porta de entrada
   didática do projeto (Regra 9 do `AGENTS.md`).
7. **O que é verificável, é verificado:** toda regra do `AGENTS.md` que puder
   ser checada por máquina vira um job do CI (`project-rules`), em vez de
   confiar em disciplina humana.

---

## 7. CI/CD — a esteira que compila e valida

O CI é parte da arquitetura: ele é o que garante que os scripts e a memória
do projeto não se degradem. Detalhes completos em [`docs/CI.md`](CI.md).

```text
                    push / pull_request
                             │
              ┌──────────────▼──────────────┐
              │      validate.yml           │  rápido (minutos)
              │  ├─ lint  (bash/shellcheck/ │
              │  │        python/yamllint)  │
              │  ├─ dry-run (xeon + ryzen)  │
              │  └─ project-rules           │  ◀── guarda as regras do AGENTS.md
              └──────────────┬──────────────┘
                             │ (merge só com verde)
                             ▼
   tag v* / manual / semanal
              ┌─────────────────────────────┐
              │      build-llama.yml        │  minutos (2 builds)
              │  ├─ xeon  (AVX2)            │
              │  ├─ ryzen (znver2)          │
              │  ├─ executa binários        │  ◀── pega SIGILL cedo
              │  ├─ inferência real (tiny)  │  ◀── prova fim-a-fim
              │  └─ Release: .tar.gz        │
              └──────────────┬──────────────┘
                             │
              push main / tag / PR em docker/**
                             ▼
              ┌─────────────────────────────┐
              │      container.yml          │  GHCR
              │  ├─ :latest  (AVX2 portável)│
              │  └─ :znver2  (Zen 2)        │
              └─────────────────────────────┘
```

### Decisão crítica: `GGML_NATIVE=OFF` em containers

No host, `GGML_NATIVE=ON` é o ideal — o CMake lê a ISA da **CPU alvo**.
Dentro do Docker, porém, "native" significa a CPU do **runner de CI**, que
pode ser Zen 4/5 **com AVX-512**. Isso geraria um binário que sofre `SIGILL`
no Xeon E5-2678 v3 e no Ryzen 5 3500X.

Por isso a imagem habilita `AVX2`/`FMA`/`F16C` **explicitamente** e mantém
`GGML_NATIVE=OFF` (Regra 12 do `AGENTS.md`).

---

## Histórico

| Data       | Mudança                                        |
|------------|------------------------------------------------|
| 2026-10-07 | Versão inicial da arquitetura (`0.1.0-alpha`). |
| 2026-10-07 | Adicionado o tutorial didático como componente (2.6) e o princípio 6. |
| 2026-10-07 | Adicionada a seção 7 (CI/CD) e o princípio 7. **Código removido:**
   variáveis mortas (`SCRIPT_DIR` em `detect-hardware.sh` e
   `llama-build.sh`; `locators` em `detect-hardware.sh`). Motivo: zerar os
   avisos do `shellcheck` exigidos pelo novo workflow `validate` — o código
   indicado nunca era lido, então nenhum comportamento mudou. Adicionado
   `--march` ao build compartilhado (habilita `znver2` no perfil ryzen). |
| 2026-10-07 | Publicada a versão `0.2.0` (marco de CI/CD). O 1º run real do
   CI revelou que o build exigia `pkg-config` (backend BLAS do ggml usa
   `find_package(PkgConfig)`) — corrigido na imagem e nos scripts do perfil
   xeon. Nenhuma alteração de comportamento além da dependência adicionada. |
