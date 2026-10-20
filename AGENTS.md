# AGENTS.md — Memória do projeto ai-cpu-os

> **LEIA ESTE ARQUIVO ANTES DE QUALQUER COISA.**
> Este é o ponto de entrada para qualquer IA (ou humano) que retome o projeto
> após um tempo parado. Ele resume o propósito, a filosofia, o hardware, a
> estrutura e — o mais importante — **as regras de trabalho**.

---

## ⚡ Retomada rápida (leia isto primeiro se chegou agora)

```bash
# 1. O essencial, nesta ordem:
#    AGENTS.md (este) → docs/STATE.md § 6 (próxima ação) → docs/JOURNAL.md
#    (§ 5 threads abertas · § 6 armadilhas já pisadas)

# 2. Sincronizar e conferir a saúde do repositório
cd /home/juju/Deep_Rock_IA
git pull --ff-only
make ci            # lint + docs + dry-run (igual ao job 'validate')

# 3. Saber o que já foi PROVADO e o que NÃO foi:
#    validate ✅ · build-llama ✅ · container ✅ · /iso ✅ GERADA E BOOTADA (VM, #21)
```

> **Regra de ouro:** não confie na memória — confie no **`docs/STATE.md` § 6
> ("Próxima ação imediata")** e no **`docs/JOURNAL.md` § 5 ("threads abertas")**.
> Os dois são reescritos ao fim de **cada** sessão de trabalho exatamente para isto.

---

## 1. Propósito do projeto

O `ai-cpu-os` transforma um Debian/Ubuntu minimal em um sistema operacional
afinado para **inferência de LLMs inteiramente em CPU**. Ele existe porque,
sem GPU, o gargalo real deixa de ser FLOPs e passa a ser **banda de memória,
latência de memória e escalonamento**. Um sistema "genérico" desperdiça ciclos
em page faults, migração de páginas, C-states profundos e swappiness agressivo
— desperdício que, somado, custa dezenas de por cento de tokens/s.

O projeto é organizado em **duas dimensões independentes** — e misturá-las é o
principal erro a evitar:

- **Família de CPU** (`families/`) — *quem é o hardware*: define `-march`, ISA e
  a política de AVX-512. Uma família cobre **dezenas de modelos** e há
  **herança** entre gerações (o tuning do Broadwell-EP vale para toda a família
  E5 **v4**; o de Haswell-EP, para toda a **v3**).
- **Papel** (`roles/`) — *para que serve a máquina*: `inference` (servidor de
  inferência) ou `builder` (Docker + registry + Gitea). Qualquer família pode
  exercer qualquer papel.
- **Mods** (`mods/`) — *modificações isoladas e reversíveis* que qualquer
  pessoa aplica e testa no seu próprio sistema operacional.

O projeto foi desenhado em torno de **dois sistemas reais**: um **servidor de
inferência** baseado em Intel Xeon E5-2680 v4 (família `intel-broadwell`,
papel `inference`) e uma **máquina de build** baseada em AMD Ryzen 5 3500X
(família `amd-zen2`, papel `builder`), que também serve um registry Docker
privado e um servidor Gitea.

Todo o sistema é gerado por **script** (`build.sh`), é **idempotente**, suporta
`--dry-run` e documenta *cada* otimização com a razão técnica de existir.

### 🎯 Entregável final: uma ISO de instalação

> **O fim do projeto NÃO é "clonar e rodar um script".** O objetivo final é uma
> **imagem ISO de instalação** de um SO — **Ubuntu Server** é a base **única**
> (ADR-001; o caminho Debian/preseed foi **removido**) — **já com o ai-cpu-os
> embutido**: você dá boot na ISO, a instalação é
> automática e o sistema nasce afinado. Isso está implementado em `iso/` e
> especificado em `docs/ISO.md`.
>
> **Não é uma ideia futura — é o critério de conclusão do projeto.** Enquanto a
> ISO não existir e não for validada, o projeto **não está terminado**, por mais
> que os scripts estejam prontos.

Arquitetura da ISO em uma frase: a ISO entrega o *software e a intenção*
(o papel); o **primeiro boot** entrega o *contexto* (o hardware real), porque é
lá que `detect-hardware.sh` vê o SMBIOS completo e escolhe a família e o papel
(`inference`/`builder`) corretamente. Ver `docs/ISO.md` § 3.

### 🧭 Decisões de arquitetura (2026-10-20) — sessões #39–#42

> Registro completo, com contexto, consequências, mapas de impacto e critérios
> de aceite: [`docs/DECISIONS.md`](docs/DECISIONS.md).
>
> - **ADR-001 — uma única base de ISO: Ubuntu Server.** ✅ **CONCLUÍDO (P0)**
>   em 2026-10-20: `iso/preseed/` foi **removido**, os scripts compartilhados
>   foram para `iso/common/`, `--distro debian` **aborta** (exit 2) citando o
>   ADR. O runtime Debian (`build.sh`/`mods/`) **continua** suportado.
> - **ADR-002 — identidade pelo papel.** `inference` → `ai-inference`;
>   `builder` → `ai-builder`; `auto` → `ai-cpu-os` + aviso; `--username` e
>   `--hostname` explícitos vencem. **Ainda não implementada.**
> - **ADR-003 — chat de frota `ai-talk`.** TCP 7331 na LAN, JSON lines,
>   HMAC-SHA256, Python stdlib; contrato em [`docs/CHAT.md`](docs/CHAT.md).
>   **Ainda não implementado.**
> - **ADR-004 — latência, espaçamento e durabilidade.** 50 ms entre `msg` do
>   mesmo par (20 msg/s), fila de 256 com exit 5, p99 ≤ 10 ms e `fsync` por
>   mensagem (§6.7/§6.8 do `CHAT.md`).
> - **ADR-005 — teto de 15 nós** em malha completa; acima disso, relay/hub é
>   obrigatório (`CHAT.md` §5.2).
>
> ⚠️ **Decisão não é fato:** o usuário padrão ainda é `ai-cpu-os` (ADR-002
> **não** implementado), e o `talk/` existe só em **F1**
> (transporte/CLI/loopback): não há serviço, ISO nem teste com duas VMs. As
> duas coisas mais próximas são **P1 (identidade)** e depois **P2/P3**
> (`docs/STATE.md` § 6).

---

## 2. Filosofia: "1% importa"

Cada otimização, por menor que pareça, é acumulada. Não buscamos um único
"truque de 2x"; buscamos **100 ganhos de 1%** que, combinados, mudam a
experiência de uso. Isso significa que:

- Nunca descartamos uma micro-otimização por "parecer pequena".
- Nunca aplicamos uma otimização sem saber **por que** ela funciona.
- Sempre medimos antes/depois (`llama-bench`) e registramos em `docs/STATE.md`.

---

## 3. Hardware alvo (resumo)

### Sistema A — Família `intel-broadwell` · papel `inference` (Servidor de IA)
- **CPU:** Intel Xeon E5-2680 v4 — 14c/28t, **Broadwell-EP**, **AVX2 apenas**
  (sem AVX-512, sem AMX). Herda o tuning de `intel-haswell` (E5 v3).
- **Placa-mãe:** JGINYUE X99M-D3 (LGA2011-3, DDR3).
- **RAM:** 16 GB DDR3-1333, 4×4 GB, **quad channel** (4 canais; Haswell-EP,
  1 pente por canal).
- **Disco:** SSD NVMe 256 GB.
- **GPU:** nenhuma (inferência 100% CPU).
- **Limitação conhecida:** modelos > 7B Q4 não cabem em 16 GB.

### Sistema B — Família `amd-zen2` · papel `builder` (Build + Registry + Gitea)
- **CPU:** AMD Ryzen 5 3500X — 6c/6t, Zen 2, **AVX2 apenas**.
- **Placa-mãe:** MSI B550 (AM4).
- **RAM:** 64 GB DDR4, 4×16 GB, operando em **SINGLE CHANNEL** ⚠️ (perda de
  ~50% de banda — o script alerta).
- **Disco:** NVMe 256 GB + HDD 1 TB.
- **GPU:** AMD RX 580 8 GB — **apenas saída de vídeo**, nunca computação
  (artefatos sob carga).
- **Função:** compilar via Docker, servir registry privado, hospedar Gitea.

---

## 4. Estrutura do repositório (comentada)

```text
ai-cpu-os/
├── README.md               # Visão geral, uso, avisos, contribuição
├── README.technical.md     # Manual do MANTENEDOR (internals, contratos, CI)
├── AGENTS.md               # ← você está aqui (ponto de entrada)
├── LICENSE                 # MIT
├── Makefile                # Atalhos locais (make ci, lint, build-xeon, docker…)
├── build.sh                # Script principal (orquestra tudo)
├── detect-hardware.sh      # Detecção de CPU/RAM/canal/disco + escolha de perfil
├── .github/
│   ├── workflows/
│   │   ├── validate.yml    # Lint + dry-run + guarda-corpo das regras (push/PR)
│   │   ├── build-llama.yml # Compila o llama.cpp por perfil + Release (tags/manual)
│   │   ├── container.yml   # Imagem de runtime no GHCR (portable / znver2)
│   │   └── iso.yml         # 🎯 Gera a ISO de instalação (tags/manual)
│   ├── ISSUE_TEMPLATE/     # Templates de issue (bug / feature)
│   ├── PULL_REQUEST_TEMPLATE.md
│   └── dependabot.yml      # Atualização de actions e da imagem base
├── docker/
│   ├── Dockerfile          # Runtime do llama.cpp (GGML_NATIVE=OFF — ver docs/CI.md)
│   └── docker-compose.example.yml
├── iso/                    # 🎯 ENTREGÁVEL FINAL: ISO de instalação
│   ├── build-iso.sh        # Remasteriza a ISO base (Ubuntu; `debian` REMOVIDO)
│   ├── verify-iso.sh       # Verifica o CONTEÚDO da ISO (ou de uma árvore: --dir)
│   ├── test-vm.sh          # Boota a ISO em qemu e espera instalação + 1º boot
│   ├── write-pendrive.sh   # 🎯 Grava a ISO num PENDRIVE (o passo mais perigoso)
│   ├── check-iso.sh        # Confere uma ISO BAIXADA sem xorriso (dd/od/sha256)
│   ├── autoinstall/        # Templates do Ubuntu (Subiquity/autoinstall)
│   │   └── autoinstall.yaml # Config de instalação automática (padrão)
│   └── common/             # Scripts do instalador (base ÚNICA: Ubuntu)
│       ├── late-command.sh # Copia o projeto p/ /opt/ai-cpu-os + rede + SSH
│       ├── firstboot.sh    # Aplica as mods no primeiro boot (hardware real)
│       └── ai-cpu-os-firstboot.service
├── docs/
│   ├── ROADMAP.md          # Concluído / Em progresso / Planejado / Ideias
│   ├── ARCHITECTURE.md     # Diagramas, fluxos, decisões de design
│   ├── STATE.md            # Estado atual + métricas + PRÓXIMA AÇÃO
│   ├── HARDWARE.md         # Detalhes técnicos do hardware alvo
│   ├── TUNING.md           # Explicação de cada otimização
│   ├── TROUBLESHOOTING.md  # Problemas conhecidos e soluções
│   ├── CI.md               # Como o GitHub compila e valida o sistema
│   ├── TUTORIAL.md         # TUTORIAL explicado (obrigatório por marco/versão)
│   ├── VALIDATION.md       # Protocolo de testes em hardware (preenchível)
│   ├── ISO.md              # 🎯 A ISO de instalação (decisões e como gerar)
│   ├── IMPLANTAR-EM-OUTRO-PC.md # 🖥️ Instalar/validar em OUTRA máquina (roteiro)
│   ├── GPU.md              # 🎮 Usar GPU (opcional, sempre explícito)
│   ├── DECISIONS.md        # 🧭 ADRs: decisões firmadas, planos e critérios
│   ├── CHAT.md             # 💬 Contrato do `ai-talk` (chat da frota)
│   └── JOURNAL.md          # 📓 Diário de sessões + continuidade (retomada)
├── families/               # 🧬 Suporte por FAMÍLIA de microarquitetura
│   ├── README.md           # Conceito família × papel, como adicionar família
│   ├── resolve.sh          # "Cérebro": casa o CPU → família → ISA/march
│   ├── _base/family.conf   # Padrões herdados por todas as famílias
│   ├── intel-haswell/      # Xeon E5 v3 (AVX2)
│   ├── intel-broadwell/    # Xeon E5 v4 (AVX2) — herda de intel-haswell
│   ├── intel-skylake-avx512/     # Xeon Scalable v5 — AVX-512 auto
│   ├── intel-cascadelake-sp/     # Xeon Scalable v6 (cascadelake) — AVX-512 auto
│   ├── intel-icelake-sp/         # Xeon Scalable v7 (icelake-server) — AVX-512 auto
│   ├── intel-sapphirerapids-sp/  # Xeon Scalable v8 (sapphirerapids) — AVX-512+AMX auto
│   ├── intel-emeraldrapids-sp/   # Xeon Scalable v9 (emeraldrapids) — AVX-512+AMX auto
│   ├── intel-graniterapids-sp/   # Xeon 6 P-cores (graniterapids) — AVX-512+AMX auto
│   ├── amd-zen1/ … amd-zen5/ # Ryzen 1000/2000 … 9000 + EPYC (herança em cadeia;
│   │                          #  zen4/zen5 têm AVX-512 auto)
│   └── generic/            # Fallback x86-64 (ISA em runtime, AVX-512 auto)
├── roles/                  # 🎯 O que a máquina FAZ (independente da CPU)
│   ├── README.md           # Fronteira papel × família
│   ├── inference/          # Servidor de inferência em CPU
│   │   ├── install.sh      # Instala deps + llama.cpp + serviço
│   │   ├── sysctl.conf     # Referência do sysctl do papel
│   │   ├── shell-ia.py     # Shell-IA em Python (tools + sandbox)
│   │   └── ai-server.service # Unit systemd do llama-server
│   └── builder/            # Build + registry + Gitea
│       ├── install.sh      # Orquestra o papel builder
│       ├── docker-setup.sh # Docker Engine + Compose
│       ├── registry-setup.sh # Registry privado localhost:5000
│       ├── gitea-compose.yml # Gitea via docker compose
│       └── build-runner.sh # Build Docker + push p/ registry local
├── llama-build.sh          # Compila o llama.cpp para a FAMÍLIA (compartilhado)
├── mods/                    # 🔧 Modificações portáveis (aplicar/testar/reverter)
│   ├── README.md            # Catálogo
│   ├── apply.sh             # Motor: list/info/check/apply/revert/test
│   ├── kernel-tuning/       # sysctl + cmdline + io_uring   (conjunto system)
│   ├── hugepages/           # THP + huge pages estáticas    (conjunto system)
│   ├── governor/            # scaling_governor=performance (conjunto system)
│   ├── openblas-threads/    # OPENBLAS_NUM_THREADS=1       (conjunto portable)
│   ├── network/             # netplan persistente (DHCP/static) — reparo do
│   │                        # alvo que subiu sem IP      (conjunto network)
│   └── apt-sources/         # fontes do apt quebradas — reparo do alvo em que
│                            # TODO apt-get update falha      (conjunto apt)
└── tests/
    ├── smoke-test.sh       # Testes rápidos pós-build
    ├── test-families.sh    # Casamento CPU → família (corpus; sem hardware)
    ├── test-avx512-policy.sh # Política de AVX-512 por família (never/optin/auto)
    ├── families-matrix.txt # ~60 modelos reais → família esperada
    ├── test-iso-selection.sh # Escolha da ISO oficial no SHA256SUMS (sem rede)
    ├── test-iso-repo-filter.sh # Repo apt: filtro + fallback (stubs; sem rede)
    ├── test-verify-iso-repo.sh # Verificador cobra o repo local (base única)
    ├── test-ci-guards.sh   # Prova que os guardas do CI REPROVAM (cópia temp.)
    ├── test-write-pendrive.sh # Travas do pendrive (gravando num ARQUIVO)
    ├── test-check-iso.sh   # Conferência de ISO baixada (fixtures byte a byte)
    ├── test-iso-lock.sh    # Trava de instância única do gerador (flock real)
    ├── test-webui.sh       # Interface web: API + salvaguardas (sem navegador)
    ├── test-ai-talk.sh     # Contrato do chat da frota (loopback, sem rede)
    └── fixtures/           # SHA256SUMS REAIS + saída REAL do apt-cache policy
├── talk/                   # 💬 `ai-talk` — chat da frota (F1 pronta; F2 = ISO)
│   ├── ai_talk.py          # daemon + CLI (stdlib; TCP 7331, JSON lines, HMAC)
│   └── README.md           # uso, `make talk-test` e o que ainda NÃO existe
└── webui/                  # 🖥️ Interface web local (criar/conferir a ISO)
    ├── server.py           # Servidor só-stdlib: lista branca de ações + SSE
    └── index.html          # Página única, sem CDN (funciona offline)
```

---

## 5. Onde encontrar cada coisa

| Preciso de...                          | Vá para...                                   |
|----------------------------------------|----------------------------------------------|
| Ver o que está feito/planejado         | `docs/ROADMAP.md`                            |
| Entender a arquitetura e os fluxos     | `docs/ARCHITECTURE.md`                       |
| **Entender o projeto POR DENTRO (mantenedor)** | **`README.technical.md`**            |
| Saber o estado atual + próxima ação    | **`docs/STATE.md`**                          |
| **Saber por que uma decisão foi tomada (ADRs)** | **`docs/DECISIONS.md`**              |
| **Saber o que está deprecado e o que será removido** | **`docs/DECISIONS.md`** (ADR-001)  |
| **Entender/implementar o chat da frota (`ai-talk`)** | **`docs/CHAT.md`**                  |
| Detalhes de CPU/RAM/disco              | `docs/HARDWARE.md`                           |
| Entender uma otimização específica     | `docs/TUNING.md`                             |
| Resolver um problema                   | `docs/TROUBLESHOOTING.md`                    |
| **Saber/testar uma otimização específica** | **`mods/`**, **`docs/MODS.md`**   |
| **Entender as famílias de CPU / adicionar uma** | **`families/README.md`**, **`docs/FAMILIES.md`** |
| **Testar o casamento CPU → família sem ter o hardware** | **`tests/test-families.sh`**, **`tests/families-matrix.txt`** |
| **Testar a escolha da ISO oficial (sem rede)** | **`tests/test-iso-selection.sh`**, **`tests/fixtures/`** |
| **Testar o repo apt local (filtro + fallback, sem rede)** | **`tests/test-iso-repo-filter.sh`** |
| **Testar o verificador da ISO sem xorriso (repo local)** | **`tests/test-verify-iso-repo.sh`** |
| **Saber se um guarda do CI reprova de verdade** | **`tests/test-ci-guards.sh`** |
| **Testar a política de AVX-512 de uma família (ligar/desligar)** | **`tests/test-avx512-policy.sh`**, **`make avx512-test`**, `docs/FAMILIES.md` § 5 |
| **Testar a trava de instância única do gerador de ISO (sem gerar ISO)** | **`tests/test-iso-lock.sh`**, **`make iso-lock-test`** |
| **Consertar a máquina JÁ instalada que está sem rede** | **`mods/network/`**, **`make network-fix`**, **`make network-test`** |
| **Consertar a máquina JÁ instalada em que TODO `apt-get update` falha** | **`mods/apt-sources/`**, **`make apt-fix`**, **`make apt-test`** |
| **Usar uma GPU (opcional, explícito)** | **`docs/GPU.md`**, `bash llama-build.sh --gpu-check` |
| **Aprender o projeto do zero (passo a passo explicado)** | **`docs/TUTORIAL.md`**        |
| Como o CI compila/valida o sistema     | `.github/workflows/`, `docs/CI.md`, `Makefile` |
| **Testar em hardware e registrar resultados** | **`docs/VALIDATION.md`**              |
| **Gerar a ISO de instalação (entregável final)** | **`iso/build-iso.sh`**, **`docs/ISO.md`** |
| **Validar a ISO (conteúdo, sem bootar)** | **`iso/verify-iso.sh`**, `docs/ISO.md` § 4.6 |
| **Testar a ISO de verdade (boot em VM)** | **`iso/test-vm.sh`**, `docs/VALIDATION.md` Bloco M |
| **Gravar a ISO num PENDRIVE (bootável)** | **`iso/write-pendrive.sh`**, `make pendrives` / `make pendrive` |
| **Conferir uma ISO baixada sem ter xorriso** | **`iso/check-iso.sh`**, `make iso-check ISO=…` |
| **Criar/conferir a ISO por uma interface web (sem decorar flags)** | **`webui/server.py`**, `make ui` (→ http://127.0.0.1:8787) |
| **Entender o instalador Ubuntu (autoinstall)** | **`iso/autoinstall/autoinstall.yaml`**, **`docs/ISO.md`** § 4.5 |
| **Retomar/continuar depois de um tempo parado** | **`docs/JOURNAL.md`** (§ 1 retomada, § 5 threads abertas) |
| Scripts principais                     | `build.sh`, `detect-hardware.sh`, `llama-build.sh` |
| Famílias de CPU (ISA/march)            | `families/`                                  |
| Papel: inferência                      | `roles/inference/`                           |
| Papel: build/registry/Gitea            | `roles/builder/`                             |
| Modificações portáveis                 | `mods/`                                      |
| Testes                                 | `tests/smoke-test.sh`                        |

---

## 6. Regras para IAs que trabalham neste projeto

Estas regras são **obrigatórias**:

1. **SEMPRE** ler `docs/STATE.md` **antes** de começar qualquer tarefa.
2. **SEMPRE** atualizar `docs/STATE.md` **ao terminar** uma tarefa
   (incluindo a seção "Próxima ação imediata").
3. **SEMPRE** atualizar `docs/ROADMAP.md` se mover algo entre
   Concluído/Em Progresso/Planejado.
4. **NUNCA** remover código sem explicar o porquê em `docs/ARCHITECTURE.md`.
5. **SEMPRE** testar em VM antes de sugerir mudanças de kernel.
6. **SEMPRE** deixar explícito o que **não** foi testado.
7. Todo script Bash: `set -euo pipefail`, logs com timestamp
   (`INFO/WARN/ERROR`), idempotência, `--dry-run` e confirmação antes de
   comandos destrutivos (salvo `--yes`).
   *Exceção única:* scripts POSIX `sh` que rodam **dentro do instalador**
   (caso de `iso/common/late-command.sh` — o `/bin/sh` do ambiente do
   instalador é dash, que não tem `pipefail`) usam `set -eu`. Isso é
   verificado pelo CI.
8. Toda verificação de ISA deve consultar `/proc/cpuinfo` **em tempo de
   execução** — nunca assumir que uma flag existe.
9. **OBRIGATÓRIO:** ao **concluir um marco** (ex.: um perfil validado em
   hardware) ou **publicar uma versão (release)**, é obrigatório
   **criar/atualizar o tutorial explicado** em `docs/TUTORIAL.md`. O
   tutorial deve cobrir o fluxo completo **do zero** (preparar o sistema →
   aplicar → usar → medir), explicando **o que** cada passo faz e **por quê**,
   em linguagem didática. Não é um documento "de uma vez só": evolui a cada
   marco. O estado do tutorial deve ser refletido em `docs/STATE.md`.
10. **NUNCA** declarar um marco/versão "concluído" sem que o
    `docs/TUTORIAL.md` correspondente esteja atualizado e coerente com o
    estado real (incluindo o que **não** foi testado).
11. **ANTES** de abrir um Pull Request, rodar `make ci` localmente e garantir
    o CI verde (workflow `validate`). Nunca faça merge com CI vermelho.
    Se você alterar os jobs, atualize `docs/CI.md`.
12. **NUNCA** escreva `-mavx512*` / `GGML_AVX512=ON` **fixo** em código,
    script ou imagem. Mas **AVX-512 não é proibido para sempre**: ele é
    decidido pela `FAMILY_AVX512_POLICY` (`never` | `optin` | `auto`) do
    `family.conf`, sempre com verificação em runtime. **Decisão do dono
    (2026-10-16):** nas famílias cujas CPUs **têm** AVX-512 (Skylake-SP+,
    Zen 4/5, EPYC Genoa/Turin), a política é **`auto`** — se a CPU reportar a
    flag, o AVX-512 é o **padrão** (mais desempenho), sem `--allow-avx512`.
    `--no-avx512` desliga (e troca o `-march` pelo fallback sem AVX-512);
    `optin` ficou reservado para exceções explícitas. Em containers,
    `GGML_NATIVE` deve permanecer `OFF` (dentro do Docker o CMake detectaria a
    CPU do runner de CI, não a do alvo).
12-b. **Padrão de build = portátil, não nativo.** O default do `llama-build.sh`
    é `GGML_NATIVE=OFF` + flags explícitas da família. Em cross-build (CI, para
    OUTRA máquina) use `--assume-family-isa`: sem isso, um runner com AVX-512
    gera binário que sofre `SIGILL` no alvo.
12-c. **GPU é opcional e SEMPRE explícita.** O projeto é de inferência 100% em
    CPU; nenhum script liga backend de GPU por conta própria (não existe
    `--gpu auto`). O caminho é `llama-build.sh --gpu <cuda|rocm|vulkan|sycl|metal>`
    (`--gpu-check` só relata). Quem usar precisa dos avisos de
    [`docs/GPU.md`](docs/GPU.md): com GPU, o tuning de CPU passa a ser
    secundário e os números de `docs/STATE.md` **não valem**. O build registra o
    backend em `AI-CPU-OS-BUILD.txt` para ninguém comparar medições
    incomparáveis. **Nenhum backend de GPU foi compilado ou testado por este
    projeto** — não declare suporte a GPU.
13. **A ISO é o entregável final e define "terminado".** Qualquer trabalho deve
    manter funcional o caminho `iso/build-iso.sh` → instalação → primeiro boot.
    Se você mudar `build.sh`, `detect-hardware.sh`, as famílias, os papéis ou o
    `docker/`, **verifique se a ISO continua coerente** (o `late-command.sh`
    copia o projeto inteiro; o `firstboot.sh` o executa). Ao mexer na ISO,
    atualize **`docs/ISO.md`** e o **Bloco M** de `docs/VALIDATION.md`.
    **Base ÚNICA = Ubuntu Server (autoinstall).** O caminho **Debian/preseed
    foi REMOVIDO** (ADR-001 em `docs/DECISIONS.md`): `--distro debian`
    **aborta** com exit 2 citando o ADR, e o CI reprova se o diretório voltar.
    Os scripts do instalador moram em `iso/common/` (não mais em
    `iso/preseed/`). O runtime Debian (`build.sh`/`mods/`) continua suportado.
    Mudou um template? Rode `make iso-yaml` — o autoteste substitui os
    marcadores e valida o `autoinstall.yaml` resultante com `yamllint` (o
    template isolado NÃO é YAML válido: `@` é reservado).
    **"Terminado" exige DUAS provas distintas**, e não confunda uma com a outra:
    `iso/verify-iso.sh` prova o **conteúdo** (não boota); `iso/test-vm.sh` prova
    o **comportamento** (boota, instala e aplica no 1º boot). Nenhuma delas
    substitui a outra.
    ⚠️ Nunca declare a ISO pronta sem tê-la **bootado e instalado** em VM.
13-a. **Um valor DEFAULT não pode fazer o build falhar.** Se a opção nasce em
    `auto` e o ambiente não permite atendê-la, **degrade com aviso explícito** —
    nunca `exit 1`. Erro fatal fica para **entrada do usuário** (um caminho que
    ele digitou errado), que é corrigível. Regra derivada de um CI vermelho real
    (sessão #18): o `--iso-repo auto` abortava no caminho Debian e derrubou o
    `validate` do GitHub enquanto o `make validate` local passava.
    **Corolário de processo:** todo comando que o CI roda precisa existir como
    alvo do `Makefile`, e o CI deve **chamar o alvo** — comando duplicado é
    comando que diverge. Há guarda no CI para os dois pontos.
13-b. **A ISO deve ser AIR-GAPPED, e o llama.cpp é compilado no 1º boot**
    (decisões firmadas; ver `docs/ISO.md` § 3.1). Consequências obrigatórias:
    - **Nunca** embutir binário pré-compilado do llama.cpp como atalho: exigiria
      uma ISO por família e reintroduziria o risco de portabilidade (`SIGILL`).
      Compilar no alvo é o que garante o `-march` correto da família detectada.
      (Há guardas no CI contra `--prebuilt` e contra `COPY build/bin`.)
    - **Nenhum passo pode exigir rede** na instalação ou no 1º boot. Tudo que
      fosse baixado tem de estar na mídia, e as três peças já estão:
      **fonte do llama.cpp** (`--iso-source`, o passo mais demorado do 1º boot),
      **modelo** (`--iso-model`, que leva o `.gguf` a `/opt/models`) e
      **toolchain + pacotes** (`--iso-repo`, repositório apt local em `/apt-repo`).
      A rede é usada **só na máquina que GERA a ISO**.
    - O repositório local entra como fonte **EXTRA**, nunca como `primary`: o
      sistema instalado tem de nascer apontando para o arquivo oficial, e um
      repositório incompleto deve **degradar** (usar rede, se houver) em vez de
      abortar a instalação. A linha `file:///cdrom/...` é removida do alvo no
      `late-command.sh`.
    - A corrente `--iso-source` → `/llama-src.tar.gz` → `LLAMA_SRC`
      (`.iso-config`) → `AI_LLAMA_SOURCE` → `llama-build.sh --source` **não pode
      quebrar em nenhum elo**: se quebrar, o 1º boot volta a clonar o llama.cpp e
      o modo de falha é silencioso. Cada elo tem guarda no CI.
    - O `llama-build.sh` **precisa** continuar aceitando `--source <dir|tar.gz>`
      (offline, sem rede e sem `git`); o papel `inference`, `--model-file`/
      `AI_MODEL_FILE`; e o `build.sh`, `--model-file`/`--llama-source` (porque
      `sudo` limpa o ambiente). Há guarda no CI para todos.
    - Se você adicionar qualquer download (script, papel, template), ele é uma
      **violação** desta regra: ou embuta na ISO, ou torne-o explicitamente
      opcional com aviso. Registre em `docs/ISO.md` § 3.1 (tabela de requisitos).
15. **Integridade da tríade `build.sh` → `detect-hardware.sh` → `families/`.**
    Ao adicionar família, papel ou mod, atualize **as três** superfícies que o CI
    cobra: a lista `required` de `.github/workflows/validate.yml`, a árvore do § 4
    deste arquivo e a tabela de `docs/MODS.md` / `docs/FAMILIES.md`.
14. **SEMPRE** registrar o fim da sessão em **`docs/JOURNAL.md`**: acrescente
    uma entrada (§ 4 — objetivo, feito, decisões, problemas, commits), atualize
    as **threads abertas** (§ 5) e as **armadilhas** (§ 6). Junto com a
    "Próxima ação imediata" do `STATE.md`, é o que garante que o trabalho possa
    ser retomado **sem perder nada**. Ver o template em `docs/JOURNAL.md` § 8.

16. **A interface web (`webui/`) é uma CONVENIÊNCIA, nunca um novo caminho.**
    Ela existe para quem não quer decorar flags — e é isso que a torna perigosa
    se crescer sem disciplina. Invariantes obrigatórios (todos com guarda no CI,
    cada um provado por violação plantada em `tests/test-ci-guards.sh`):
    - **Só executa o que está na lista branca** (`ACTIONS` em `server.py`). A UI
      **nunca** aceita comando, caminho de script ou nome de alvo vindo do
      navegador: ela monta a linha de comando a partir de valores **validados**
      (`v_disk`, `v_family`, `v_distro`, `v_network_mode`, `v_net_ip`, …) e
      chama os alvos do `Makefile`.
    - **Escuta só em `127.0.0.1`** e **recusa** explicitamente outra interface
      (amarrar em `0.0.0.0` exporia uma página que gera ISO e particiona disco).
    - **Somente biblioteca padrão.** Nada de `fastapi`/`flask`/`pip install`:
      a máquina do usuário pode ser limitada, e ele não pode ser obrigado a
      instalar nada para gerar a ISO.
    - **Senhas só as do usuário/root DA ISO, e sempre como hash crypt.**
      Gravar pendrive exige root; a UI só **lista** os dispositivos e mostra o
      comando pronto para o usuário rodar no terminal — **nenhuma senha de sudo
      entra no navegador, no servidor ou em log** (decisão do dono, 2026-10-16).
      As senhas do usuário/root da ISO são aceitas no formulário (campos
      `type=password`), viram **hash crypt** (`crypt`/`openssl passwd -6`) ANTES
      da linha de comando, e só o hash chega ao `build-iso.sh`
      (`--password-hash`/`--root-password-hash`). Texto puro só existe em
      memória; os guardas do CI proíbem flag de senha em texto puro e `sudo -S`.
    - **Não tem rota de escrita arbitrária.** Se um dia precisar, isso é uma
      decisão de arquitetura — não um atalho.
    - **A ISO não leva o `webui/`** (`--exclude=./webui` no `build-iso.sh`): é
      ferramenta da máquina que GERA a mídia, não do sistema instalado
      (Regra 13-b).
    - A UI **não implementa nada**: quando falta `xorriso`, ela diz *por que* não
      dá para gerar ali e aponta o caminho do GitHub Actions — degradar com
      aviso explícito (Regra 13-a), nunca falhar em silêncio.

17. **Identidade do sistema = papel (ADR-002 em `docs/DECISIONS.md`).**
    O usuário/hostname padrão de uma ISO com papel concreto é
    `inference` → `ai-inference` e `builder` → `ai-builder`. Precedência:
    `--username`/`--hostname` explícitos **sempre** vencem; sem eles, o papel
    concreto define; `--role auto` mantém `ai-cpu-os` e **avisa** (o papel só é
    conhecido no 1º boot, então não dá para derivar a identidade no instalador).
    Não renomeie usuário depois da instalação e não crie dois usuários para
    “escolher depois”. A função é a identidade; o hardware continua sendo a
    **família**.
18. **`ai-talk` é transporte, não orquestrador (ADR-003, `docs/CHAT.md`).**
    Invariantes obrigatórios:
    - **Não é o `talk` do netkit.** Nada de `talkd`, UDP 517/518 ou protocolo
      antigo; o componente é `talk/` + binário `ai-talk` (TCP 7331, JSON lines,
      HMAC-SHA256).
    - **Somente biblioteca padrão do Python 3.** Nada de `pip`, Matrix, MQTT,
      IRC, broker ou serviço externo.
    - **Mensagem é dado, nunca comando.** O `ai-talk` não executa shell; a
      ponte opcional com o `llama-server` não executa tool calls vindas da rede.
    - **Sem chave, não inicia** (fail closed). A chave não vai para o
      repositório, para o log nem para o `.iso-config`; vai para
      `/etc/ai-talk/fleet.key` com permissão restrita.
    - **Air-gapped:** o código vai na ISO; nenhum passo de instalação/1º boot
      baixa nada (Regra 13-b).
    - **Falha do chat não derruba a inferência:** instalação/daemon degradam com
      aviso e o `build.sh` continua (Regra 13-a).
    - **O teto é de 15 nós** em malha completa (ADR-005). Acima disso, o
      caminho é relay/hub — não “aumentar o teto” sem a bancada de 15 nós.
    - **Teste offline no CI** (`tests/test-ai-talk.sh`) e, na fase 2, duas VMs
      (Bloco R de `docs/VALIDATION.md`). Não declare o chat pronto sem os dois.

---

## 7. Próxima ação imediata

👉 Ver a seção **"Próxima ação imediata"** em
[`docs/STATE.md`](docs/STATE.md).

---

## 8. Última atualização

- **Data:** 2026-10-20 (sessão #42)
- **O que mudou:** 🗑️ **ADR-001 executado: o caminho Debian da ISO foi
  removido.** `iso/preseed/` saiu (os scripts compartilhados foram para
  `iso/common/`), `--distro debian` **aborta** com exit 2 citando o ADR,
  `iso/verify-iso.sh` ficou com uma base só e o CI ganhou guardas provados:
  reprova se `preseed/` voltar ao `build-iso.sh`/`verify-iso.sh` ou se o
  diretório reaparecer. O layout da mídia mudou: os templates agora vão para
  **`/ai-cpu-os-boot/`** (era `/preseed/`). `make validate` **verde**
  (ci-guards 93, ai-talk 30, webui 46, iso-lint OK). ⚠️ **Nenhuma ISO foi
  gerada nem bootada depois da remoção** — a prova de comportamento continua
  sendo a da sessão #21/#35 (antes da mudança).
- **Data anterior:** 2026-10-20 (sessões #39–#41)
- **O que mudou:** 💬 **O `ai-talk` saiu do papel: a F1 está implementada e
  testada.** `talk/ai_talk.py` (somente stdlib) traz daemon + CLI com TCP 7331,
  JSON lines, HMAC-SHA256 **por nó**, `ack` **depois do `fsync`**,
  `TCP_NODELAY`, conexão persistente, espaçamento de **50 ms por par** (fila
  de 256 com **exit 5**), dedupe de **8.192** IDs e **teto de 15 peers**.
  `make talk-test` (30 asserções, loopback, sem root e sem rede externa) prova
  a semântica de §6.7/§6.8 e entrou no `validate` e no CI. Antes disso, a
  sessão #39 criou **`docs/DECISIONS.md`** e **`docs/CHAT.md`**, e a #40 fixou
  **ADR-004** (latência/espaçamento/durabilidade) e **ADR-005** (teto de 15
  nós). `--distro debian` emite aviso de depreciação. **Não há Debian
  removido, identidade por papel, `talk/install.sh`, ISO com o chat, duas VMs
  nem bancada de 15 nós.**
- **Data anterior:** 2026-10-20 (sessão #39)
- **O que mudou:** 🧭 **Preparação da fase “uma ISO, duas funções, uma
  frota”** — sem implementar as três mudanças. Foram criados
  **`docs/DECISIONS.md`** (ADR-001: base **única Ubuntu**, Debian/preseed
  deprecado e remoção P0; ADR-002: identidade por papel
  `ai-inference`/`ai-builder`; ADR-003: chat de frota **`ai-talk`**) e
  **`docs/CHAT.md`** (contrato completo: TCP 7331, JSON lines, HMAC-SHA256,
  Python stdlib, systemd, segurança, testes, fases e por que **não** usar o
  `talk` do netkit). O `iso/build-iso.sh` passou a **avisar** que
  `--distro debian` está deprecado; `make docs` e o CI passaram a exigir os
  dois documentos. `STATE.md` § 6, `ROADMAP.md`, `JOURNAL.md` (sessão #39) e
  `ARCHITECTURE.md`/`ISO.md`/READMEs foram atualizados. **Nada de código
  Debian removido, nenhuma identidade implementada, nenhum `talk/` criado,
  nenhuma ISO gerada.** ⚠️ O `main` já estava no commit `bf2117f` (sessão
  #38), à frente deste arquivo; a preparação foi feita sobre esse estado.
- **Data anterior:** 2026-10-18 (sessão #37)
- **O que mudou:** 🖥️ **Primeira validação em HARDWARE FÍSICO** (não é mais só
  VM). Uma máquina real — **AMD A8-9600** (Excavator), Debian 13 — instalou a
  ISO sozinha, o 1º boot aplicou o ai-cpu-os (`status=ok`, família `generic`,
  que é o **fallback correto**), o llama.cpp compilou **do tarball da mídia sem
  rede**, o **SSH funcionou e sobreviveu ao reboot**, o tuning persistiu
  (swappiness 10, numa_balancing 0, THP always, governor performance) e foi
  medida a **primeira inferência do projeto**: `pp64 17,05 t/s` · `tg32 10,40
  t/s` (4 threads, BLAS, 1.5B Q4_K_M). `smoke-test` **12/12**;
  `verify-iso` da ISO usada **PASS=56**. Também corrigido um log enganoso: o
  `llama-build.sh` dizia "forçada por --family" para uma família que o projeto
  havia **detectado** (agora diz "detectada e repassada pela cadeia").
  **Bloco Q** em `docs/VALIDATION.md`, § 3.6 em `STATE.md`, sessão #37 no
  `JOURNAL.md`. ⚠️ **As duas máquinas de referência (Xeon E5-2680 v4 e Ryzen 5
  3500X) continuam sem validação** — e não há "antes" para medir o ganho.
- **Data anterior:** 2026-10-18 (sessão #35)
- **O que mudou:** **A ISO Debian passou a funcionar — instalada e bootada em
  VM.** O caminho `--distro debian` (preseed + isolinux) **nunca havia sido
  executado**; agora ele instala sozinho, **reinicia sozinho** e o 1º boot
  aplica o ai-cpu-os (`status=ok`, família detectada, llama.cpp compilado no
  alvo). Foram **10 travas, todas mudas** — nenhuma dá mensagem de erro, o
  sintoma é sempre "a VM fica parada": preseed tem de ir **dentro do initrd**
  (`/preseed.cfg` na raiz, via `inject_preseed_initrd`); `prompt 0` no
  isolinux; `localechooser/languagelist` além de `language=` na cmdline;
  `grub-installer/bootdev`; hash crypt **nunca** entre aspas duplas (`"$6$…"`
  expande `$6` e o late-command morre com `exit 2`); remoção do
  `deb cdrom:` que o próprio instalador grava; `sudo` (não vem no Debian);
  marcador do 1º boot no `/dev/ttyS0` (no alvo, `/dev/console` é o **último**
  `console=` → tty1); e `timeout` em cada sonda de rede do 1º boot.
  `verify-iso.sh` **PASS=51**, `ci-guards` 63 → **76**. Detalhe:
  `docs/STATE.md` § 3.4, Bloco M.0b de `docs/VALIDATION.md` e `JOURNAL.md` § 4.
- **Data anterior:** 2026-10-17 (sessão #33)
- **O que mudou:** **A rede do sistema instalado passou a ser preparada na ISO
  — e foi PROVADA EM VM.** O alvo agora pega IP sozinho e aceita SSH. Uma
  instalação real subia **sem DHCP** — a placa ficava DOWN até alguém
  configurar à mão — porque o Subiquity **não grava configuração de rede
  persistente no alvo** quando o `autoinstall.yaml` não tem a chave `network:`.
  A correção segue o padrão da senha: a intenção é decidida na geração da ISO.
  Novas flags `--network auto|dhcp|static|none` (padrão `auto` = DHCP),
  `--network-interface`, `--network-ip` (aceita `/N`), `--network-gateway`,
  `--network-dns`, `--network-prefix`. O **mesmo** bloco netplan vai para o
  `autoinstall.yaml` e para `/preseed/ai-cpu-os-netplan.yaml`; o
  `late-command.sh` o instala em `/etc/netplan/99-ai-cpu-os.yaml` (0600), move o
  netplan do instalador/cloud-init para `.ai-cpu-os.bak` e grava
  `/etc/cloud/cloud.cfg.d/99-ai-cpu-os-disable-network.cfg`
  (`network: {config: disabled}`). No Debian as flags alimentam o `netcfg` da
  preseed (e o hostname da preseed, que era fixo, passou a usar
  `@@HOSTNAME@@`). O **default nunca derruba o build** (Regra 13-a). O
  `verify-iso.sh` ganhou a seção "Rede do sistema instalado"; o `make iso-yaml`
  exercita `auto`/`static`/`none` nos dois layouts de disco; a webui ganhou o
  seletor de rede com validadores próprios. **Três bugs reais** foram achados ao
  executar (não ao revisar): arquivos de **0 byte** após o 1º boot (um unit
  vazio vira **`masked`** — o `ai-server` não existia), `--no-mmap` **removido
  do llama.cpp** (o serviço entrava em loop) e o `shell-ia.py` devolvendo a
  linha do **protocolo** como resposta. Medido no alvo (4 vCPU, AVX2):
  `smoke-test` 11 PASS/1 FAIL (governor sem `cpufreq` na VM),
  `ai-server /health` = `{"status":"ok"}` e **`llama-bench` pp64 46,55 t/s ·
  tg32 25,95 t/s**. Guardas: `ci-guards` **46**, `webui` **46**. **Falta:**
  modo `static`, hardware físico, caminho Debian e UEFI.

- **Data anterior:** 2026-10-16 (sessão #32)
- **O que mudou:** **`validate` #57 vermelho — o teste da trava dependia de uma
  otimização que o bash NÃO promete.** O `tests/test-iso-lock.sh` segurava a
  trava num `bash -c '…; sleep 30' &` e a soltava com `kill`, contando que o
  bash **trocasse de identidade** pelo último comando (*exec*). Essa otimização
  não é garantida — basta um `BASH_ENV` com `trap` para o bash desistir dela, e
  aí o `sleep` é um **filho que herda o fd 9**: a trava sobrevive ao `kill` e a
  asserção final reprova **com o gerador correto** (no CI: `exit code 2` num
  passo de 6 s — os 5 s do laço de espera estourando). O teste foi reescrito
  (**10 → 13 asserções**): detentor determinístico (`sleep 300 9>&- &` + `wait`,
  `flock -w 20` para não perder a corrida para as sondas do próprio teste — que
  também o deixava **flaky**), pré-voo que exige a trava livre e aponta **quem**
  a segura, e todo `FALHOU` virando **anotação** `::error::` (o único canal
  público sem token). Diagnóstico e modo de falha reproduzível em
  `docs/JOURNAL.md` § 4 (sessão #32) e § 6; `make validate` verde.

- **Data anterior:** 2026-10-16
- **O que mudou:** **A "correção" do SIGILL do `build-llama` não corrigia — e o
  trabalho local de 14/10 foi recuperado (sessão #33).** (1) **Sync:** o `main`
  local estava **7 commits atrás** e com trabalho **não commitado**; foi
  preservado numa branch de backup (`backup/local-sessao26-pre-sync`) e
  alinhado a `origin/main` (o `push` voltou a ser fast-forward). (2) **O bug:**
  a correção do #28 punha `matrix.exec != 'false'` num **`if:`** — e, no GitHub,
  **booleano × string** vira **número** (`false`→0, `'false'`→NaN), então o
  `!=` dá **sempre true** e os passos de execução **nunca** eram pulados: as
  famílias AVX-512/AMX rodaram no runner sem a ISA e tomaram SIGILL
  (`exit 132`) **no próprio commit da correção**. O valor agora vai por `env:`
  e a decisão é no `bash` (o padrão que já funcionava no passo 7); guarda no
  `project-rules` + violação plantada no `ci-guards-test`. (3) **Recuperado do
  trabalho local (que não existia no GitHub):** `flock` de instância única +
  `download_to()` (confere o `.part`, aborta download estagnado) no
  `build-iso.sh`, com `make iso-lock-test` (**10** asserções); e
  `make avx512-test` (37 → **61** asserções, cobrindo as **14** famílias).
  Duas armadilhas novas registradas no `JOURNAL.md` § 6. `ci-guards`: 35 →
  **40**.

- **Data anterior:** 2026-10-16 — **Senha de usuário/root na webui + 14 famílias
  + AVX-512 por padrão (sessões #26 e #27).** (1) A webui ganhou campos de **senha do
  usuário** e **senha do root** (opcional) para a ISO: o texto vira **hash
  crypt** no servidor (stdlib `crypt`; no Python 3.13+, `openssl passwd -6
  -stdin` — sem depender de `mkpasswd`) e só o hash entra na linha de comando
  (`--password-hash`/`--root-password-hash`); a senha nunca aparece em log nem
  no `argv`. O root é habilitado no **Ubuntu** via late-command (`chpasswd -e`)
  e no **Debian** via preseed (`@@ROOT_PRESEED@@` → `root-login true`); sem
  senha, o root continua **bloqueado** (padrão). O `verify-iso.sh` ganhou a
  seção "Senha do root" (coerência hash × preseed × late-command). Guardas do
  CI atualizados: proibido `sudo -S`/flag de senha em texto puro; obrigatório o
  hash crypt — `ci-guards 35/35`, `webui 38/38`. **A Regra 16 mudou nesse
  ponto**: a UI continua sem lidar com senha de sudo, mas aceita as senhas DA
  ISO como hash. (2) As **famílias de CPU** foram expandidas para 14 (Xeon
  Scalable v5–v9, Xeon 6 P-cores, Zen 5/EPYC Turin) com **AVX-512 como padrão**
  (política `auto`) nas famílias que o têm — ver Regra 12.
- **Data anterior:** 2026-10-15
- **O que mudou:** **Interface web local para gerar/conferir a ISO (sessão #24).**
  Entrou `webui/` (`server.py` + `index.html`) para quem não quer decorar flags:
  a página mostra o hardware detectado, o espaço livre e quais ferramentas
  existem, monta o `make iso` com o que você escolher, roda e vai imprimindo o
  log **ao vivo** (SSE), lista as ISOs em `iso/out` com botões de conferir, e
  **lista os pendrives** mostrando o comando `sudo make pendrive …` pronto para
  copiar (a UI nunca pede senha). **Provado com `make ui-test`** (34 asserções):
  a página é servida, **não usa CDN**, a lista branca recusa `../`, disco/serviço
  inválido e JSON quebrado, o `/api/jobs/<id>` valida o formato do id, o SSE
  entrega log + `done`, e — o ponto central — **sem `xorriso` ela RECUSA gerar
  com o motivo explícito** e aponta o GitHub Actions (Regra 13-a), em vez de
  falhar em silêncio. Ela só usa **biblioteca padrão** (esta máquina é limitada:
  `pip install` não pode ser pré-requisito para gerar a ISO) e escuta **só em
  `127.0.0.1`**. Nova **Regra 16** com os invariantes, cada um com guarda no CI
  provado por violação plantada (`make ci-guards-test`: 22 → **31** casos).
  `webui/` **fica de fora da ISO** (`--exclude=./webui`) — é ferramenta da
  máquina que gera a mídia, não do sistema instalado. Alvos novos: `make ui` e
  `make ui-test` (este no `validate`, no CI e no dry-run local).
  **Nada disso foi aberto num navegador de verdade** — o teste exercita a API.
- **Data anterior:** 2026-10-14 — **A ISO volta a ser BAIXÁVEL + conferência sem `xorriso` (sessão #23).**
  O workflow gateava o **artifact** pelo limite de **2 GiB**, que é de **asset de
  Release** (os limites documentados do `upload-artifact` são número por job e
  perda de permissões). Resultado cruel: a ISO air-gapped (~4 GB) era gerada e
  **descartada**, e quem não tem `xorriso` — a máquina de desenvolvimento é
  assim — ficava **sem nenhum caminho** para obter o arquivo. Agora só a Release
  é gateada (`release_too_big`) e o artifact sobe **sempre**, com guarda no CI.
  Entrou **`iso/check-iso.sh`** + `make iso-check ISO=…`: confere uma ISO
  **baixada** com `dd`/`od`/`sha256sum` (tamanho, SHA256, assinatura `CD001`,
  Volume ID `AI_CPU_OS_*`, assinatura de boot) — **sem `xorriso` e sem root**,
  complementando (não substituindo) o `verify-iso.sh`, que prova o **conteúdo**.
  Teste `make iso-check-test` (20 asserções, fixtures byte a byte) cobrindo os
  modos de falha reais, inclusive o mais comum: o navegador entregar o
  **artifact (`.zip`)** em vez do `.iso`. `make ci-guards-test` passou a
  **provar** os guardas novos (22 casos).
- **Data anterior:** 2026-10-14 — **O passo final existe: `iso/write-pendrive.sh` (sessão #22).**
  `make pendrives` lista os candidatos (só removíveis) e
  `sudo make pendrive DEVICE=/dev/sdX` grava com **9 travas** — recusa o disco
  que contém `/`, recusa não-removível sem `--allow-internal`, exige **disco
  inteiro** (`TYPE=disk`: um `sr0`/DVD tem `RM=1` e passaria), recusa partição
  montada, exige assinatura `CD001`, confere se **cabe**, avisa se o
  dispositivo for muito maior que a ISO, exige digitar o **nome** do alvo e
  **lê de volta** comparando byte a byte (`cmp -n` com `conv=fsync`). `--yes`
  pula só a pergunta, **nunca** as travas. O teste (`make pendrive-test`, 16
  asserções) grava num **ARQUIVO** e simula o `lsblk` — nenhum dispositivo real
  é tocado. **Nenhum pendrive físico foi gravado ainda.** Também corrigido o bug
  que derrubava o run #15 **com a ISO já gerada** (`exit 127`: uma mensagem de
  aviso com a linha partida virava comando solto) e uma nota desatualizada do
  `README.md` que dizia que a ISO nunca havia sido bootada (a sessão #21 provou
  que foi).
- **Data anterior:** 2026-10-13
- **O que mudou:** 🎉 **A ISO foi GERADA e BOOTADA pela primeira vez — o
  critério de conclusão do projeto (§ 1) foi cumprido.** Numa máquina com 24
  vCPU + `/dev/kvm` + Docker (que destravou o que era "bloqueado por ambiente"),
  a ISO **air-gapped** (fonte do llama.cpp + modelo + repositório apt na mídia)
  foi construída **dentro de um container `ubuntu:24.04`** e **instalada numa VM
  com KVM**: instalou sozinha, reiniciou e o **1º boot aplicou o ai-cpu-os**
  (`status=ok`, família `intel-haswell` detectada no alvo), compilando o
  llama.cpp **do tarball da mídia, sem rede**. `verify-iso.sh` **PASS=41/FAIL=0**;
  `test-vm.sh` **exit 0**. No caminho, **8 bugs reais** só visíveis ao EXECUTAR
  foram corrigidos: `xorriso` (`-rm --`, `-boot_image replay`, `-map` do
  modelo/fonte/repo, aspas do `-find`), SIGPIPE no `verify-iso.sh`, **GRUB sem
  `--id`** (a instalação automática **nunca** acontecia — subia a entrada
  interativa), **repo apt declarado no apt do instalador** (o curtin roda
  `apt-get update` num chroot sem `/cdrom` → agora o late-command carrega o repo
  para o **alvo** `/opt/apt-repo`) e os **marcadores** (não saíam no console
  serial). Ver `docs/STATE.md` § 3.3 e `docs/JOURNAL.md` sessão #21.
  **Pendências:** caminho **Debian**, **UEFI**, **hardware físico** (Blocos
  A–O) e um resíduo air-gapped (o build do llama.cpp ainda busca o UI do
  HuggingFace). Regra 13 satisfeita **para o Ubuntu em VM** — não para Debian
  nem hardware.
- **Data anterior:** 2026-10-12 — **Os runs #9 e #10 da ISO (sessão #20).**
  O **#9 (ubuntu)** falhou com `Pacote pedido está AUSENTE: git` — **só `git`**: o
  filtro de candidatos resolveu `gnupg` e `jq`, e sobrou uma falha
  **intermitente de rede** (pega no meio do download, indistinguível de "pacote
  não existe" no log). Corrigido com `Acquire::Retries` e uma **segunda
  tentativa só dos ausentes** (`repo_missing_packages`), que custa segundos em
  vez de repetir 330 MB. O **#10 (debian)** era **falso positivo do próprio
  verificador**: o `verify-iso.sh` procurava o repositório em uso **só no
  `/autoinstall.yaml`** — que não existe numa ISO Debian (o Debian usa preseed)
  — e reprovava uma ISO **correta** ("2 problema(s)"). Agora a checagem é
  **distro-aware** (autoinstall × preseed), com `make iso-verify-test` provando
  os dois caminhos e **reprovando o verificador antigo**. Também: dependências
  **implícitas do runner** (`openssl`, `gzip`, `ca-certificates`) passaram a ser
  instaladas explicitamente — descobertas reproduzindo o build num container
  `ubuntu:24.04` limpo; e o passo de diagnóstico do `iso.yml` passou a capturar
  `[FAIL]`/`[erro]` do verificador (antes só via `[ERROR]`, então a anotação
  entregava o sintoma sem a causa).
- **Data anterior:** 2026-10-12 — **A ISO Ubuntu + `air_gapped=true` não era gerada (sessão #19, 2ª parte).**
  O passo de diagnóstico que criei na 1ª parte funcionou e entregou a causa:
  `Pacote pedido está AUSENTE no repositório: gnupg/jq/git`. Causa **medida**:
  `apt-get download a b c` **aborta o lote inteiro** quando um dos nomes não tem
  candidato — e o script baixava em lotes de 25 com `|| true`, perdendo até 25
  pacotes por lote em silêncio. Corrigido com `packages_with_candidate()`
  (descarta virtuais antes de baixar) + fallback um-a-um no lote que falha +
  **reportar** os nomes que falharam. Teste novo `make iso-repo-test` (13
  asserções, offline, com stubs de `apt-get`/`apt-cache`). **E um achado maior:
  SEIS guardas negativos do CI estavam na forma `! cmd`, que o `set -e`
  IGNORA** — nunca derrubaram nada. Todos convertidos para
  `if cmd; then exit 1; fi`, mais meta-guarda proibindo a forma antiga e o teste
  `make ci-guards-test` (14 casos), que planta cada violação numa cópia
  temporária e exige que o job falhe.
- **Data anterior:** 2026-10-12 — **Limpeza + CI consertado (sessão #18).** O CI
  estava **vermelho no `main`** e ninguém tinha visto: o `--iso-repo auto`
  (default) abortava no caminho Debian e derrubava o passo "ISO (dry-run dos
  dois caminhos)". Corrigido com a **Regra 13-a** (default degrada, nunca
  aborta) e com o corolário de que o CI e o `make` compartilham o comando
  (`make iso-dry-run-both`). Também: `iso.yml` estava preso em `actions/*@v4`
  enquanto o resto do repo já usava `@v6`/`@v7` (o bump do Dependabot não o
  alcançou); runner fixado em `ubuntu-24.04` nos jobs que dependem da release
  (o label `ubuntu-latest` migra para Ubuntu 26 em 2026-10-19 e mudaria o
  resultado sozinho); `build-llama` agora **compila do tarball** (`--source`),
  exercitando o caminho offline com cmake real nas 7 famílias; `upload-artifact`
  **padronizado em `@v7`** nos dois workflows (sobrava um `@v6` que só o PR #3
  do Dependabot trazia) com guarda de CI negativo+positivo; removido o
  diretório fantasma `profiles/` e corrigida a entrada obsoleta no `.gitignore`.
  Novos guardas no CI para todos esses invariantes. **PRs:** #1 mesclado, #2
  (`debian:13-slim`) verde e sem conflito, #3 resolvido direto no `main`
  (pode fechar).
- **Data anterior:** 2026-10-12 — **O repositório apt também vai na mídia** (orçamento de 8 GB
  acordado). `--iso-repo auto|<dir>|none` resolve o **fecho de dependências** dos
  pacotes que o 1º boot precisa, baixa os `.deb`, gera o índice com `dpkg-deb`
  (**sem `dpkg-dev`**) e os embute em `/apt-repo`. A fonte entra como **extra**
  (seção `sources` do curtin no Ubuntu; `apt-setup/local0/*` no Debian) para o
  `primary` continuar sendo o arquivo oficial — o alvo nasce com `apt` normal, e
  um repositório incompleto degrada em vez de abortar. O build **recusa**
  repositório de outra release. Com isso os 5 itens do § 3.1 do `docs/ISO.md`
  estão implementados; **falta só o item 2** (`firstboot.sh` usar `--source`),
  que é o que ainda faz o 1º boot precisar de rede para clonar o llama.cpp.
  Prova real feita: o **`apt` do sistema aceitou** um repositório montado pelo
  código do projeto e resolveu dependência; o `verify-iso.sh` reprova os 5 modos
  de falha testados. **Nenhuma ISO gerada; nenhum boot real.**
- **Data anterior:** 2026-10-12 — **O modelo `.gguf` vai na mídia** (resposta à dúvida em
  aberto): ~1 GB de ISO é preço justo por uma mídia que se basta. Implementado
  `--iso-model auto|<caminho>|none` no `iso/build-iso.sh` (recusa `.gguf`
  inválido — magic `GGUF` — **antes** de montar a ISO), a cópia para
  `/opt/models` no `late-command.sh` (`MODEL_FILE` no `.iso-config`), o repasse
  no `firstboot.sh` (`AI_MODEL_FILE`) e **`--model-file`** no papel `inference`
  (instala um modelo local sem rede). O `iso/verify-iso.sh` confere a corrente
  toda e reprova modelo inválido/pequeno; guardas novos no CI, incluindo
  **negativos** (proibido `--prebuilt` e `COPY build/bin`).
  **A ISO ainda exige rede no 1º boot** para o toolchain e o clone do llama.cpp —
  o repositório apt local segue como o item mais pesado em aberto.
- **Data anterior:** 2026-10-12 — **Decisões firmadas sobre a ISO (Regra 13-b):
  air-gapped e compilar no 1º boot.** A ISO **deve funcionar sem internet** e o llama.cpp é
  **compilado no alvo** — nunca um binário pré-compilado (exigiria uma ISO por
  família e reintroduziria o risco de `SIGILL`). Consequência prática: nenhum
  download novo pode entrar em script/papel/template sem ser embutido na mídia
  ou explicitamente opcional. Plano completo com o estado de cada um dos 6
  requisitos em `docs/ISO.md` § 3.1. **Item 1 implementado:**
  `llama-build.sh --source <dir|tar.gz>` — compila de um fonte **local**, sem
  rede e sem `git`, registrando a origem (e `Rede: não usada`) no
  `AI-CPU-OS-BUILD.txt`; guarda no CI. **A ISO ainda exige rede no 1º boot** —
  os itens 2–5 são plano. Nova dúvida registrada: o modelo `.gguf` vai na mídia?
- **Data anterior:** 2026-10-12 — **Documentação separada por público.** `README.md` foi
  reescrito para o **usuário final** (explicado do zero: serve para mim?, o que
  muda na minha máquina, instalação em 5 passos, uso diário, como medir, como
  desfazer, FAQ) e criado o **`README.technical.md`** — manual do **mantenedor**
  (modelo mental das três camadas, mapa do repo, contratos/invariantes, receitas
  de "como estender", o que cada teste prova, CI por dentro, playbook de
  depuração com os bugs reais, status de validação e glossário). Regra derivada:
  **usuário → `README.md`; mantenedor → `README.technical.md`; regras → este
  arquivo; "o que é fato hoje" → `docs/STATE.md`.** Corrigido de passagem um bug
  real: o `build-llama.yml` ainda usava `matrix.profile` (removido na
  refatoração) no nome do artefato — o upload falharia.
- **Data anterior:** 2026-10-12 — **Ferramentas de validação da ISO.** Criados
  `iso/verify-iso.sh` (confere o **conteúdo** da ISO — config, projeto embutido,
  marcadores, YAML, entrada de boot, Volume ID — com modo `--dir` que dispensa
  `xorriso`, o que o torna testável no CI) e `iso/test-vm.sh` (boota a ISO em
  qemu, espera a instalação e o primeiro boot por **marcadores no console
  serial**). Nova flag `--serial-console` no build (console ttyS0 na ISO **e** no
  sistema instalado) e o build agora **verifica a ISO ao final**. `make
  iso-yaml` roda o verificador sobre uma árvore real **com teste negativo**
  (reprovar quando falta a config). Novos alvos `make iso-verify` e `make
  iso-vm`. `docs/ISO.md` § 4.6 e Bloco M distro-aware. **Nenhuma ISO gerada;
  `test-vm.sh` nunca executado (sem qemu no ambiente).**
- **Data anterior:** 2026-10-12 — **ISO em base Ubuntu Server
  (autoinstall/Subiquity).** `--distro ubuntu` passou a ser o padrão
  (Debian/preseed segue como legado), com a config em
  `iso/autoinstall/autoinstall.yaml` na raiz da ISO e remontagem por `xorriso
  -indev/-outdev -map` (setores de boot da ISO oficial preservados — sem
  `mtools`/`isohdpfx.bin`). O `late-command.sh` passou a ser compartilhado pelos
  dois instaladores (`AI_CURTIN=1`) e a ISO grava **papel + família** (não mais
  "perfil"). Novo autoteste de templates (`--check-templates` / `make iso-yaml`)
  validando o `autoinstall.yaml` substituído com `yamllint`, rodando no CI.
  Docs: `ISO.md` § 4.5 e Bloco M distro-aware; passada mecânica corrigindo
  caminhos quebrados em todo o `docs/`. **Nenhuma ISO gerada/bootada.**
- **Data anterior:** 2026-10-12 — **Refatoração para FAMÍLIAS de CPU + PAPÉIS +
  MODS.** Suporte deixou de ser "um processador por perfil" e passou a ser por
  **família de microarquitetura com herança** (`families/`, 8 famílias, AVX-512
  por política), com **papéis** separados do hardware (`roles/inference`,
  `roles/builder`) e **mods portáveis** aplicáveis/reversíveis em qualquer
  sistema (`mods/`, com `apply`/`revert`/`test`). O build do llama.cpp virou um
  script único dirigido pela família (`llama-build.sh`), com padrão **portátil**
  (`GGML_NATIVE=OFF`) e modo `--assume-family-isa` para cross-build. Sistema de
  referência passou a **Ubuntu Server**. CPU do Sistema A: E5-2680 v4
  (Broadwell-EP, 14c/28t). Comentários do README aplicados e removidos.
- **Data anterior:** 2026-10-07 — Criado **`docs/JOURNAL.md`** (diário de
  sessões + continuidade) e a seção "Retomada rápida"; nova **Regra 14**.
  Unificado o hardware: o Xeon é **quad channel**.
- **Data anterior:** 2026-10-07 — Registrado o **entregável final = ISO de
  instalação** (meta no § 1, regra 13) e criada a implementação em `iso/`.
- **Data anterior:** 2026-10-07 — Criado `docs/VALIDATION.md` — protocolo
  preenchível de testes em hardware (blocos A–L).
- **Data anterior:** 2026-10-07 — Adicionada a esteira de CI/CD
  (`.github/workflows/`: `validate`, `build-llama`, `container`), `Makefile`,
  `docker/` e `docs/CI.md`. Novas regras 11 e 12.
- **Data anterior:** 2026-10-07 — Criação do `docs/TUTORIAL.md` e da diretriz
  de tutorial obrigatório por marco/versão.
- **Data anterior:** 2026-10-07 — Criação inicial do repositório (todos os
  scripts, perfis e documentação da versão `0.1.0-alpha`).
